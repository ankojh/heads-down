import AppKit
import Combine
import EventKit

/// Optional calendar auto-focus. Watches the macOS calendars (EventKit) for the event active now and,
/// when armed, starts a calendar-owned session with a brief built from that event.
///
/// Lifecycle is independent of screen capture (an event can start while focus is off):
///
///   check (~30 s, jittered; also on calendar-store changes, wake, clock change, event boundaries) →
///   resolve current event (CurrentEventResolver) → brief (local rules, or the optional local agent;
///   cached by content fingerprint + the user's answer) → start / update / end only a calendar-owned
///   session
///
/// Typed tasks win, Stop skips the current event(s), and an indefinite pause holds auto-start until
/// the user resumes. Logs carry categories and counts only, never event text.
/// Local counters for the Inspector.
struct CalendarStats {
    var polls = 0
    var failures = 0
    var briefCacheHits = 0
    var briefsPrepared = 0
    var agentRuns = 0
}

@MainActor
final class CalendarAutomation: ObservableObject {
    static let shared = CalendarAutomation()

    static let pollInterval: TimeInterval = 30
    static let pollJitter: TimeInterval = 4
    /// A calendar-owned session survives failed checks this long (and never past its event's end).
    static let freshnessGrace: TimeInterval = 120
    private static let autoStartKey = "calendarAutoStart"
    private static let agentKey = "calendarBriefAgent"
    private static let maxCachedBriefs = 32
    static let maxAnswerChars = 200

    @Published private(set) var connected = EventKitCalendarSource.hasAccess
    @Published private(set) var accessDenied = EventKitCalendarSource.wasDenied
    @Published private(set) var connecting = false
    @Published private(set) var autoStartEnabled = UserDefaults.standard.bool(forKey: autoStartKey)
    /// Write briefs with the local Ollama agent instead of the fixed rules.
    @Published private(set) var agentEnabled = UserDefaults.standard.bool(forKey: agentKey)
    /// Why the agent can't run right now (Ollama down, model missing), for the panel.
    @Published private(set) var agentProblem: String?
    @Published private(set) var lastAgentRun: AgentRunInfo?
    /// The current brief's clarifying question, until answered or dismissed.
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var status: AutomationStatus = .disconnected
    /// The event automation is following (shown in the panel, never logged).
    @Published private(set) var currentEvent: CalendarEvent?
    @Published private(set) var overlapping = 0
    @Published private(set) var brief: FocusBrief?
    @Published private(set) var lastPollAt: Date?
    @Published private(set) var lastPollMs: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var stats = CalendarStats()
    @Published private(set) var pausedByUser = false

    private weak var session: SessionController?
    private let source = EventKitCalendarSource()
    private let localCompressor = LocalBriefCompressor()
    private lazy var agent = OllamaBriefAgent()
    private var compressor: CalendarContextCompressor { agentEnabled ? agent : localCompressor }
    /// The user's answers to agent questions, per occurrence. In memory only.
    private var answers: [String: String] = [:]
    /// Questions the user dismissed without answering, per occurrence.
    private var dismissedQuestions = Set<String>()
    /// Bumped on disable, disconnect, and shutdown: in-flight results from before are ignored.
    private var epoch: UInt64 = 0
    private var timerTask: Task<Void, Never>?
    private var polling = false
    private var lastSuccessAt: Date?
    /// Log what the store can see (counts only) when nothing is found: on "Check now", else every 10 min.
    private var storeSummaryDue = true
    private var lastStoreSummaryAt = Date.distantPast
    private var lastEligible: [CalendarEvent] = []
    private var upcomingStarts: [Date] = []
    private var briefCache: [String: FocusBrief] = [:]
    private var observers: [NSObjectProtocol] = []
    private let suppressions = CalendarSuppressions()

    // MARK: - Setup

    func setUp(session: SessionController) {
        self.session = session
        session.onUserStop = { [weak self] in self?.userStopped() }
        session.onIndefinitePause = { [weak self] in self?.userPausedIndefinitely() }
        session.onUserResume = { [weak self] in self?.userResumed() }
        session.revalidateCalendarResume = { [weak self] occurrence in
            await self?.revalidate(occurrence) ?? false
        }
        session.onTaskApplied = { [weak self] task, source in
            guard self?.agentEnabled == true else { return }
            TaskHistory.shared.record(task, source: source == .manual ? "typed" : "calendar")
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.boundaryChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.boundaryChanged() } })
        // Edits synced by macOS (or made in Calendar.app) arrive here; no need to wait for the next check.
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: source.store, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.storeChanged() } })
        suppressions.prune()
        updateIdleStatus()
        if connected, autoStartEnabled { refreshSoon() }
    }

    func shutdown() {
        epoch += 1
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Access

    /// Asks macOS for Calendars access (first time only); after a denial, opens System Settings.
    func connect() {
        guard !connecting else { return }
        if EventKitCalendarSource.wasDenied {
            openPrivacySettings()
            return
        }
        connecting = true
        lastError = nil
        Task {
            let granted = await source.requestAccess()
            connecting = false
            connected = granted
            accessDenied = !granted
            session?.log(["event": granted ? "calendar_connected" : "calendar_connect_failed"])
            if granted {
                updateIdleStatus()
                refreshSoon()
            } else {
                lastError = "Calendar access was not granted. Allow Heads Down in System Settings → Privacy & Security → Calendars."
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS access was revoked in System Settings: stop calendar work and end only an owned session.
    private func accessLost() {
        epoch += 1
        timerTask?.cancel()
        timerTask = nil
        endOwnedSession(reason: "calendar access removed")
        connected = false
        accessDenied = true
        clearEventContext()
        status = .disconnected
        session?.log(["event": "calendar_access_lost"])
    }

    // MARK: - Brief agent

    /// Turning the agent on checks Ollama once (a problem is shown, not fatal: briefs fall back to
    /// the fixed rules). Turning it off deletes the local task history it used.
    func setAgentEnabled(_ enabled: Bool) {
        guard enabled != agentEnabled else { return }
        agentEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.agentKey)
        briefCache = [:]
        pendingQuestion = nil
        agentProblem = nil
        if enabled {
            if let task = session?.currentTask, session?.runState != .stopped {
                TaskHistory.shared.record(task, source: session?.taskSource == .manual ? "typed" : "calendar")
            }
            checkAgent()
        } else {
            TaskHistory.shared.clear()
            lastAgentRun = nil
        }
        session?.log(["event": "calendar_agent", "enabled": enabled])
        if connected { refreshSoon() }
    }

    func checkAgent() {
        guard agentEnabled else { return }
        Task {
            let problem = await agent.health()
            guard agentEnabled else { return }
            agentProblem = problem
        }
    }

    var agentModel: String { agent.model }

    /// The user's answer to the agent's question: the brief is rewritten once with it.
    func answerQuestion(_ text: String) {
        let answer = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxAnswerChars))
        guard !answer.isEmpty, let event = currentEvent else { return }
        answers[event.occurrence.storageKey] = answer
        pendingQuestion = nil
        session?.log(["event": "calendar_agent_answered"])
        refreshSoon()
    }

    func dismissQuestion() {
        guard let event = currentEvent else { return }
        dismissedQuestions.insert(event.occurrence.storageKey)
        pendingQuestion = nil
    }

    // MARK: - Arming

    /// Turning auto-start on is where permission and outbound-data consent happen, once, so polling
    /// never shows a dialog.
    func setAutoStart(_ enabled: Bool) {
        guard enabled != autoStartEnabled else { return }
        guard enabled else {
            epoch += 1
            timerTask?.cancel()
            timerTask = nil
            endOwnedSession(reason: "calendar auto-start turned off")
            setAutoStartPreference(false)
            updateIdleStatus()
            session?.log(["event": "calendar_autostart", "enabled": false])
            return
        }
        guard connected, let session else { return }
        if session.provider.sendsTextOffDevice {
            guard confirmCalendarDisclosure(), session.confirmCloudConsent() else { return }
        }
        if !(session.screenRecordingGranted || Permissions.screenRecordingGranted) {
            Permissions.requestScreenRecording()
            session.notice = "Calendar auto-start needs Screen Recording. Allow Heads Down in System Settings."
        }
        setAutoStartPreference(true)
        pausedByUser = false
        session.log(["event": "calendar_autostart", "enabled": true])
        refreshSoon()
    }

    /// Clears a skip or pause hold for the current event and checks again.
    func resumeThisEvent() {
        if let event = currentEvent { suppressions.remove(event.occurrence) }
        pausedByUser = false
        refreshSoon()
    }

    /// One fetch to show the current event, also when auto-start is off.
    func checkNow() {
        storeSummaryDue = true
        source.requestSourceRefresh()
        refreshSoon()
    }

    // MARK: - Session hooks

    private func userStopped() {
        guard connected, autoStartEnabled, let session else { return }
        // Skip every eligible event active now (and the owned one), so an overlapping event can't
        // immediately restart what the user just stopped.
        var skipped = lastEligible.filter { ($0.end ?? .distantPast) > Date() }
        if let owned = session.taskSource.occurrence, !skipped.contains(where: { $0.occurrence == owned }),
           let event = currentEvent, event.occurrence == owned {
            skipped.append(event)
        }
        guard !skipped.isEmpty else { return }
        for event in skipped { suppressions.suppress(event) }
        status = .skipped
        session.log(["event": "calendar_suppressed", "count": skipped.count])
    }

    private func userPausedIndefinitely() {
        guard connected, autoStartEnabled else { return }
        pausedByUser = true
        status = .pausedByUser
    }

    private func userResumed() {
        guard pausedByUser else { return }
        pausedByUser = false
        refreshSoon()
    }

    /// Before a timed pause resumes a calendar-owned session: check again; resume only if the event
    /// is still current and eligible.
    private func revalidate(_ occurrence: CalendarOccurrence) async -> Bool {
        await poll()
        guard connected, autoStartEnabled, let event = lastEligible.first(where: { matches($0.occurrence, occurrence) }),
              let end = event.end, Date() < end, !suppressions.contains(event)
        else { return false }
        return Date().timeIntervalSince(lastSuccessAt ?? .distantPast) <= Self.freshnessGrace
    }

    // MARK: - Polling

    func refreshSoon() {
        schedule(after: 0.2)
    }

    /// Wake or a clock change: absolute event times may have passed. Only while armed.
    private func boundaryChanged() {
        guard autoStartEnabled else { return }
        enforceLocalDeadlines()
        refreshSoon()
    }

    /// The calendar store changed (sync or local edit). Also catches access granted in Settings.
    private func storeChanged() {
        if !connected, EventKitCalendarSource.hasAccess {
            connected = true
            accessDenied = false
            updateIdleStatus()
        }
        guard connected, autoStartEnabled || currentEvent != nil else { return }
        schedule(after: 1)
    }

    private func schedule(after delay: TimeInterval) {
        guard connected else { return }
        timerTask?.cancel()
        let epoch = epoch
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(max(0.05, delay) * 1000)))
            guard !Task.isCancelled, let self, self.epoch == epoch else { return }
            await self.poll()
        }
    }

    private func poll() async {
        guard connected, !polling, let session else { return }
        polling = true
        defer { polling = false }
        let epoch = epoch
        enforceLocalDeadlines()
        let now = Date()
        let fetch: CalendarFetch
        do {
            fetch = try source.currentEvents(now: now)
        } catch {
            stats.failures += 1
            accessLost()
            return
        }
        lastSuccessAt = fetch.fetchedAt
        lastPollAt = Date()
        lastPollMs = fetch.ms
        lastError = nil
        stats.polls += 1
        await apply(fetch, epoch: epoch)
        guard self.epoch == epoch else { return }
        session.log([
            "event": "calendar_poll", "ms": Int(fetch.ms), "events": fetch.events.count,
            "eligible": lastEligible.count, "complete": fetch.complete, "status": statusCategory,
        ])
        if fetch.events.isEmpty, storeSummaryDue || Date().timeIntervalSince(lastStoreSummaryAt) > 600 {
            storeSummaryDue = false
            lastStoreSummaryAt = Date()
            session.log(["event": "calendar_store"].merging(source.storeSummary(now: Date())) { $1 })
        }
        // With auto-start off a check is one-off (e.g. "Check now"); nothing keeps polling.
        if autoStartEnabled { scheduleNext() }
    }

    private func apply(_ fetch: CalendarFetch, epoch: UInt64) async {
        guard let session else { return }
        let now = Date()
        let owned = session.taskSource.occurrence
        let resolution = CurrentEventResolver.resolve(
            fetch.events, now: now, keeping: owned ?? currentEvent?.occurrence,
            usable: { CalendarContextBuilder.insufficiency(CalendarContextBuilder.sanitize($0)) == nil })
        lastEligible = resolution.eligible
        upcomingStarts = fetch.events.compactMap(\.start).filter { $0 > now }
        overlapping = max(0, resolution.eligible.count - 1)

        // The owned event ended, was cancelled, or became ineligible: end only that session.
        if let owned, !resolution.eligible.contains(where: { matches($0.occurrence, owned) }) {
            session.endCalendarTask(owned, reason: "the event ended or changed")
        }
        guard let event = resolution.selected else {
            currentEvent = nil
            brief = nil
            status = autoStartEnabled
                ? (resolution.skippedReasons.first.map { .notEligible($0) } ?? .noEvent) : .disabled
            return
        }
        if currentEvent?.occurrence != event.occurrence {
            answers = answers.filter { $0.key == event.occurrence.storageKey }
            dismissedQuestions = dismissedQuestions.filter { $0 == event.occurrence.storageKey }
        }
        currentEvent = event

        let sanitized = CalendarContextBuilder.sanitize(event)
        let answer = answers[event.occurrence.storageKey]
        let compressor = compressor
        let key = OllamaBriefAgent.fingerprint(sanitized, answer: answer, compressorID: compressor.id)
        let prepared: FocusBrief
        if let cached = briefCache[key] {
            prepared = cached
            stats.briefCacheHits += 1
        } else {
            if session.taskSource.occurrence != event.occurrence, autoStartEnabled {
                status = agentEnabled ? .preparingWithAgent : .preparing
            }
            prepared = await compressor.brief(from: sanitized, answer: answer)
            guard self.epoch == epoch else { return }
            if briefCache.count >= Self.maxCachedBriefs { briefCache.removeAll() }
            briefCache[key] = prepared
            stats.briefsPrepared += 1
            if compressor is OllamaBriefAgent {
                lastAgentRun = agent.lastRun
                stats.agentRuns += 1
                agentProblem = prepared.agentNote?.hasPrefix("local agent unavailable") == true ? prepared.agentNote : nil
                session.log(["event": "calendar_agent_run", "turns": agent.lastRun?.turns ?? 0,
                             "fetches": agent.lastRun?.fetches ?? 0, "asked": agent.lastRun?.asked ?? false,
                             "ms": Int(agent.lastRun?.ms ?? 0)])
            }
        }
        brief = prepared
        pendingQuestion = answer == nil && !dismissedQuestions.contains(event.occurrence.storageKey)
            ? prepared.question : nil
        guard autoStartEnabled else {
            status = .disabled
            return
        }
        // Re-check the clock after awaiting.
        guard let end = event.end, Date() < end else { return }

        if session.taskSource.occurrence == event.occurrence {
            if prepared.insufficientReason != nil {
                session.endCalendarTask(event.occurrence, reason: "the event no longer has topic details")
                status = .insufficientContext
                return
            }
            // Same fingerprint → same text → no revision bump. End-time changes only move the deadline.
            session.updateCalendarTask(prepared, occurrence: event.occurrence)
            status = session.runState == .paused && pausedByUser ? .pausedByUser : .active(until: end)
            return
        }
        if session.hasManualSession {
            status = .manualPriority
            return
        }
        if pausedByUser {
            status = .pausedByUser
            return
        }
        if suppressions.contains(event) {
            status = .skipped
            return
        }
        if prepared.insufficientReason != nil {
            status = .insufficientContext
            return
        }
        guard session.runState == .stopped else { return }
        status = .preparing
        let occurrence = event.occurrence
        let problem = await session.startCalendarTask(prepared, occurrence: occurrence) { [weak self] in
            guard let self else { return false }
            return self.epoch == epoch && self.autoStartEnabled && self.connected && !self.pausedByUser
                && !self.suppressions.contains(event) && Date() < end && !(self.session?.hasManualSession ?? true)
        }
        guard self.epoch == epoch else { return }
        if let problem {
            status = problem == "cancelled" ? status : .blocked(problem)
        } else {
            status = .active(until: end)
        }
    }

    /// Next poll: the regular interval, or sooner at an event boundary (owned event end, a start
    /// seen in the query window, the freshness grace deadline).
    private func scheduleNext() {
        let now = Date()
        var delay = Self.pollInterval + Double.random(in: -Self.pollJitter...Self.pollJitter)
        var boundaries = upcomingStarts
        if let end = currentEvent?.end { boundaries.append(end) }
        for boundary in boundaries where boundary > now {
            delay = min(delay, boundary.timeIntervalSince(now) + 0.5)
        }
        schedule(after: max(1, delay))
    }

    /// Ends a calendar-owned session at its known end without waiting for the network.
    private func enforceLocalDeadlines() {
        guard let session, let owned = session.taskSource.occurrence else { return }
        if let event = currentEvent, event.occurrence == owned, let end = event.end, Date() >= end {
            session.endCalendarTask(owned, reason: "the event ended")
        }
    }

    private func endOwnedSession(reason: String) {
        guard let session, let owned = session.taskSource.occurrence else { return }
        session.endCalendarTask(owned, reason: reason)
    }

    // MARK: - Helpers

    private func matches(_ lhs: CalendarOccurrence, _ rhs: CalendarOccurrence) -> Bool {
        lhs == rhs || (lhs.connectionID == rhs.connectionID && lhs.mirrorKey != nil && lhs.mirrorKey == rhs.mirrorKey)
    }

    private func setAutoStartPreference(_ enabled: Bool) {
        autoStartEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoStartKey)
    }

    private func clearEventContext() {
        currentEvent = nil
        brief = nil
        briefCache = [:]
        pendingQuestion = nil
        answers = [:]
        dismissedQuestions = []
        lastEligible = []
        upcomingStarts = []
        overlapping = 0
        lastSuccessAt = nil
        pausedByUser = false
    }

    private func updateIdleStatus() {
        if !connected {
            status = .disconnected
        } else if !autoStartEnabled {
            status = .disabled
        } else {
            status = .checking
        }
    }

    private var statusCategory: String {
        switch status {
        case .active: return "active"
        case .noEvent: return "no_event"
        case .notEligible: return "not_eligible"
        case .insufficientContext: return "insufficient"
        case .manualPriority: return "manual_priority"
        case .skipped: return "skipped"
        case .pausedByUser: return "paused"
        case .blocked: return "blocked"
        case .disabled: return "disabled"
        default: return "other"
        }
    }

    private func confirmCalendarDisclosure() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Send a calendar-based task to Jev?"
        alert.informativeText = """
            With auto-start on, Heads Down builds the task from the current event in your macOS \
            calendars: its title, and its description and location with links, emails, phone \
            numbers, and dial-in codes removed. If the local brief agent is on, the task can also \
            summarize pages linked from the event and your answer to its question. That task is \
            sent to Jev (TypeSafe) with every screen region it scores. Attendees and join links \
            are never sent.

            Heads Down only reads your calendars; it never changes them.
            """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
