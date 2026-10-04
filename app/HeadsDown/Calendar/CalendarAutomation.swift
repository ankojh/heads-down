import AppKit
import Combine

/// Optional Google Calendar auto-focus. Watches the primary calendar for the event active now and,
/// when armed, starts a calendar-owned session with a brief built from that event.
///
/// Lifecycle is independent of screen capture (an event can start while focus is off):
///
///   poll (~30 s, jittered; backoff on failure; also on wake, clock change, event boundaries) →
///   resolve current event (CurrentEventResolver) → brief (CalendarContextBuilder, cached by content
///   fingerprint) → start / update / end only a calendar-owned session
///
/// Typed tasks win, Stop skips the current event(s), an indefinite pause holds auto-start until the
/// user resumes, and a failed request is never treated as "no event". Logs carry categories and
/// counts only, never event text.
/// Local counters for the Inspector.
struct CalendarStats {
    var polls = 0
    var failures = 0
    var briefCacheHits = 0
    var briefsPrepared = 0
}

@MainActor
final class CalendarAutomation: ObservableObject {
    static let shared = CalendarAutomation()

    static let pollInterval: TimeInterval = 30
    static let pollJitter: TimeInterval = 4
    static let maxBackoff: TimeInterval = 300
    /// A calendar-owned session survives failed polls this long (and never past its event's end).
    static let freshnessGrace: TimeInterval = 120
    static let calendarID = "primary"
    private static let autoStartKey = "calendarAutoStart"
    private static let connectionKey = "calendarConnectionID"
    private static let maxCachedBriefs = 32

    @Published private(set) var connected = GoogleCalendarAuth.hasStoredGrant
    @Published private(set) var connecting = false
    @Published private(set) var autoStartEnabled = UserDefaults.standard.bool(forKey: autoStartKey)
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
    private let auth = GoogleCalendarAuth()
    private lazy var client = GoogleCalendarClient(auth: auth)
    private let compressor: CalendarContextCompressor = LocalBriefCompressor()
    /// Bumped on disable, disconnect, and shutdown: in-flight results from before are ignored.
    private var epoch: UInt64 = 0
    private var timerTask: Task<Void, Never>?
    private var polling = false
    private var failureCount = 0
    private var lastSuccessAt: Date?
    private var lastEligible: [CalendarEvent] = []
    private var upcomingStarts: [Date] = []
    private var briefCache: [String: FocusBrief] = [:]
    private var observers: [NSObjectProtocol] = []
    private let suppressions = CalendarSuppressions()

    private var connectionID: String {
        if let saved = UserDefaults.standard.string(forKey: Self.connectionKey) { return saved }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.connectionKey)
        return fresh
    }

    var isConfigured: Bool { GoogleCalendarAuth.clientID != nil }

    // MARK: - Setup

    func setUp(session: SessionController) {
        self.session = session
        session.onUserStop = { [weak self] in self?.userStopped() }
        session.onIndefinitePause = { [weak self] in self?.userPausedIndefinitely() }
        session.onUserResume = { [weak self] in self?.userResumed() }
        session.revalidateCalendarResume = { [weak self] occurrence in
            await self?.revalidate(occurrence) ?? false
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.boundaryChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.boundaryChanged() } })
        suppressions.prune()
        updateIdleStatus()
        if connected, autoStartEnabled { refreshSoon() }
    }

    func shutdown() {
        epoch += 1
        timerTask?.cancel()
        timerTask = nil
        Task { await auth.cancelAuthorization() }
    }

    // MARK: - Connection

    func connect() {
        guard !connecting else { return }
        guard isConfigured else {
            lastError = CalendarAuthError.notConfigured.errorDescription
            return
        }
        connecting = true
        lastError = nil
        Task {
            defer { connecting = false }
            do {
                try await auth.authorize()
                UserDefaults.standard.set(UUID().uuidString, forKey: Self.connectionKey)
                connected = true
                session?.log(["event": "calendar_connected"])
                updateIdleStatus()
                refreshSoon()
            } catch {
                lastError = (error as? CalendarAuthError)?.errorDescription ?? "sign-in failed"
                session?.log(["event": "calendar_connect_failed"])
            }
        }
    }

    func cancelConnect() {
        Task { await auth.cancelAuthorization() }
    }

    /// Disables automation, cancels calendar work, ends only a calendar-owned session, clears event
    /// context, and removes tokens locally before asking Google to revoke them.
    func disconnect() {
        epoch += 1
        timerTask?.cancel()
        timerTask = nil
        endOwnedSession(reason: "Google Calendar disconnected")
        setAutoStartPreference(false)
        connected = false
        clearEventContext()
        suppressions.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.connectionKey)
        status = .disconnected
        session?.log(["event": "calendar_disconnected"])
        Task { await auth.disconnect() }
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

    /// Before a timed pause resumes a calendar-owned session: fetch again; resume only if the event
    /// is still current and eligible. If Google can't be reached, the last good answer counts only
    /// within the freshness grace and the event's known end.
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
            fetch = try await client.currentEvents(calendarID: Self.calendarID, connectionID: connectionID, now: now)
        } catch {
            guard self.epoch == epoch else { return }
            handleFailure(error as? CalendarFetchError ?? .network)
            return
        }
        guard self.epoch == epoch else { return }
        failureCount = 0
        lastSuccessAt = fetch.fetchedAt
        lastPollAt = Date()
        lastPollMs = fetch.ms
        lastError = fetch.complete ? nil : "more events than one check reads; showing a partial result"
        stats.polls += 1
        await apply(fetch, epoch: epoch)
        guard self.epoch == epoch else { return }
        session.log([
            "event": "calendar_poll", "ms": Int(fetch.ms), "events": fetch.events.count,
            "eligible": lastEligible.count, "complete": fetch.complete, "status": statusCategory,
        ])
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
        currentEvent = event

        let sanitized = CalendarContextBuilder.sanitize(event)
        let key = CalendarContextBuilder.fingerprint(sanitized, compressorID: compressor.id)
        let prepared: FocusBrief
        if let cached = briefCache[key] {
            prepared = cached
            stats.briefCacheHits += 1
        } else {
            if session.taskSource.occurrence != event.occurrence, autoStartEnabled { status = .preparing }
            prepared = await compressor.brief(from: sanitized)
            guard self.epoch == epoch else { return }
            if briefCache.count >= Self.maxCachedBriefs { briefCache.removeAll() }
            briefCache[key] = prepared
            stats.briefsPrepared += 1
        }
        brief = prepared
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

    private func handleFailure(_ error: CalendarFetchError) {
        stats.failures += 1
        failureCount += 1
        lastError = error.category
        session?.log(["event": "calendar_poll_failed", "category": error.category])
        if error.needsAuthorization {
            // No retry loop on revoked or invalid credentials; can't stay fresh, so end owned focus.
            if case .auth(.invalidGrant) = error { connected = false }
            endOwnedSession(reason: "calendar authorization lost")
            status = .needsAuthorization(error.category)
            timerTask?.cancel()
            return
        }
        // A failure isn't "no event": keep a calendar-owned session only within the grace period.
        if let owned = session?.taskSource.occurrence,
           Date().timeIntervalSince(lastSuccessAt ?? .distantPast) > Self.freshnessGrace {
            session?.endCalendarTask(owned, reason: "Google Calendar unreachable")
        }
        status = .degraded(error.category)
        guard autoStartEnabled else { return }
        let backoff = min(Self.maxBackoff, Self.pollInterval * pow(2, Double(min(failureCount - 1, 4))))
        schedule(after: backoff + Double.random(in: 0...Self.pollJitter))
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
            With auto-start on, Heads Down builds the task from the current event in your primary \
            Google Calendar: its title, and its description, location, and attachment names with \
            links, emails, phone numbers, and dial-in codes removed. That task is sent to Jev \
            (TypeSafe) with every screen region it scores. Attendees and join links are never sent.

            Heads Down's Google access is read-only. Google's read-only scope can see all your \
            calendars' events; Heads Down only reads the primary calendar.
            """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
