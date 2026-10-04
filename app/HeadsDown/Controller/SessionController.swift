import AppKit
import Combine

struct DisplayChoice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// Runs the autonomous loop once the user starts a task. See SessionController+Pipeline.swift for
/// the tick/cycle pipeline; this file holds state, lifecycle, controls, and the timed pause.
///
/// Three things are tracked separately:
/// - observation freshness (thumbnail baseline, dirty reasons, retained OCR),
/// - semantic decisions (score cache keyed by the exact classifier payload, strict policy),
/// - visual coverage (a cover drawn from the latest thumbnail, minus chrome/occluders/keep holes).
///
/// Scrolling is a fourth, geometry-only lane (SessionController+Scroll.swift): covers follow
/// measured pane movement between reads, and fall back to masking the pane when it can't be measured.
///
/// This is rule-based orchestration of local tools, not an LLM planner.
@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    static let tickInterval: Duration = .milliseconds(400)
    /// Wait this long after a change (once content is settled) before re-reading.
    static let debounce: TimeInterval = 0.6
    /// Never defer a meaningful change longer than this, even if content keeps changing.
    static let maxDirtyDelay: TimeInterval = 2.0
    static let minCycleGap: TimeInterval = 0.5
    /// Animation in covered areas only triggers a recheck this often.
    static let motionRecheckInterval: TimeInterval = 15
    static let motionStreakTicks = 3
    /// More than this fraction of cells changed = layout change (scroll, navigation): close all
    /// keep holes and re-read the whole window.
    static let layoutChangeFraction = 0.3
    static let settledChangeFraction = 0.02
    /// Above this fraction of the window height in changed bands, OCR the whole window.
    static let fullOCRBandFraction: CGFloat = 0.5
    static let maxRetainedOCRAge: TimeInterval = 60
    /// Paid classification waits until the pointer has stopped scrolling the window this long.
    static let scrollQuiet: TimeInterval = 0.4
    static let maxCaptureBackoff: TimeInterval = 10
    /// Scroll tracking cadence while a pane is moving (screenshot path, so a conservative cap).
    static let trackInterval: TimeInterval = 1.0 / 15
    /// Keep measuring this long after the last wheel event (momentum and smooth-scroll animations).
    static let trackQuiet: TimeInterval = 0.5
    /// After a mid-scroll re-read, newly exposed content that had no score yet stays under the
    /// transition mask this long (Balanced/Relaxed, panes that had covered content only).
    static let exposureHoldTime: TimeInterval = 4
    static let timedPauseChoices = [3, 2]
    static let maxRetainedWindows = 6

    // MARK: - Published state

    @Published var taskDraft = ""
    @Published var currentTask: String?
    /// Who chose `currentTask`. A typed task always wins; calendar automation only starts, updates,
    /// or ends sessions it owns (see SessionController+Calendar.swift).
    @Published var taskSource: TaskSource = .manual
    @Published var taskRevision = 0
    @Published var sessionID: String?
    @Published var mode: CoverMode = CoverMode(rawValue: UserDefaults.standard.string(forKey: "coverMode") ?? "")
        ?? .blur {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "coverMode")
            if oldValue != mode { modeChanged() }
        }
    }
    /// Changing strictness re-applies policy to cached scores; nothing is reclassified.
    @Published var strictness: Strictness = Strictness(
        rawValue: UserDefaults.standard.string(forKey: "strictness") ?? "") ?? .balanced {
        didSet {
            UserDefaults.standard.set(strictness.rawValue, forKey: "strictness")
            guard oldValue != strictness else { return }
            rebuildDecisions()
            render()
            log(["event": "strictness", "strictness": strictness.rawValue])
        }
    }
    /// Jev (default, after one-time consent) or local Laya. Scores are cached per provider.
    @Published var provider: ClassifierProvider = SessionController.initialProvider {
        didSet {
            guard oldValue != provider else { return }
            if provider.sendsTextOffDevice, !confirmCloudConsent() {
                provider = .laya
                return
            }
            UserDefaults.standard.set(provider.rawValue, forKey: "classifierProvider")
            classifierChanged()
        }
    }
    @Published var showBoxes = UserDefaults.standard.object(forKey: "showBoxes") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showBoxes, forKey: "showBoxes")
            render()
        }
    }
    @Published var runState: RunState = .stopped
    @Published var activity = "Idle"
    @Published var regions: [ScreenRegion] = []
    @Published var decisions: [String: RegionDecision] = [:]
    /// Regions whose pixels changed since they were read. Their keep holes close until re-read.
    @Published var changedRegionIDs: Set<String> = []
    /// Regions actually left visible (keep holes) in the last render.
    @Published var visibleRegionIDs: Set<String> = []
    @Published var renderedCover = "None"
    /// Scroll tracking state for the Inspector (session-local pane numbers, no content).
    @Published var scrollStatus = "Not scrolling"
    /// Cover image refresh state for the Inspector.
    @Published var coverStatus = "No cover image"
    @Published var coverage: Coverage?
    @Published var lastTimings: CycleTimings?
    @Published var classifierStatus = "Not checked"
    /// Per-session classifier usage (requests, tokens, reuse), for the Inspector.
    @Published var usage = ClassificationStats()
    @Published var screenRecordingGranted = Permissions.screenRecordingGranted
    @Published var accessibilityGranted = Permissions.accessibilityGranted
    @Published var displays: [DisplayChoice] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID() {
        didSet { if oldValue != selectedDisplayID { displaySelectionChanged() } }
    }
    @Published var selectedRegionID: String?
    @Published var hotKeyStatus = "Not registered"
    @Published var notice: String?
    @Published var diagnosticsEnabled = UserDefaults.standard.object(forKey: "diagnosticsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(diagnosticsEnabled, forKey: "diagnosticsEnabled") }
    }
    /// Set while a timed pause is counting down (sleep-aware clock).
    @Published var pauseDeadline: ContinuousClock.Instant?

    var isActive: Bool { [.observing, .processing, .degraded].contains(runState) }
    var controlCount: Int { controlRects.count }
    var classifierEndpoint: String { classifier.endpointDescription }
    var classifierName: String { classifier.displayName }

    static let jevConsentKey = "jevConsent"
    static var initialProvider: ClassifierProvider {
        let saved = ClassifierProvider(rawValue: UserDefaults.standard.string(forKey: "classifierProvider") ?? "") ?? .jev
        // Never start on a cloud provider without recorded consent.
        return saved == .jev && !UserDefaults.standard.bool(forKey: jevConsentKey) ? .laya : saved
    }

    static func makeClassifier(_ provider: ClassifierProvider) -> DistractionClassifier {
        switch provider {
        case .jev: return JevClient()
        case .laya: return LayaClient()
        }
    }

    var menuBarSymbol: String {
        switch runState {
        case .stopped: return "eye"
        case .requestingPermissions: return "lock.shield"
        case .paused: return pauseDeadline == nil ? "pause.circle" : "timer"
        case .degraded: return "exclamationmark.triangle"
        case .observing, .processing: return "eye.circle.fill"
        }
    }

    /// Remaining timed-pause time, derived from the deadline (never a decremented counter).
    var pauseRemaining: Duration? {
        guard let pauseDeadline else { return nil }
        return max(.zero, pauseDeadline - ContinuousClock.now)
    }

    // MARK: - Pipeline state (internal for SessionController+Pipeline.swift)

    /// Owns when classifier requests are sent; see ClassificationScheduler.swift.
    let scheduler = ClassificationScheduler(classifier: SessionController.makeClassifier(SessionController.initialProvider))
    var classifier: DistractionClassifier { scheduler.classifier }
    let capturer = ScreenCapturer()
    let overlay = OverlayController()
    let coverQueue = CoverRenderQueue()
    /// Blurs of scrolled panes from tracking captures; separate so they never delay the window cover.
    let paneCoverQueue = CoverRenderQueue()
    let overrides = RevealOverrides()
    var scoreCache = ScoreCache(limit: 2000)
    var observers: [NSObjectProtocol] = []
    var scrollMonitor: Any?

    var loopTask: Task<Void, Never>?
    /// The single expensive-work lane (capture/AX/OCR/classify). Cleared only when the work
    /// really finishes, so superseded work can't overlap a new cycle.
    var laneTask: Task<Void, Never>?
    var autoResumeTask: Task<Void, Never>?
    var sessionGeneration: UInt64 = 0
    var cycleCounter: UInt64 = 0
    var activeCycleID: UInt64 = 0
    var pauseToken: UInt64 = 0

    var target: TargetWindow?
    var chrome: ContentEnvelope.Chrome?
    /// Interactive controls from the last accessibility read; never covered.
    var controlRects: [CGRect] = []
    /// Covers kept on windows that are no longer frontmost but still visible.
    var retainedWindows: [CGWindowID: RetainedWindow] = [:]
    /// Thumbnail matching the frame the current regions/OCR came from.
    var baseline: Thumbnail?
    var latestThumb: Thumbnail?
    /// When the latest thumbnail's capture started.
    var latestThumbAt = Date.distantPast
    var motionStreak: [Int] = []
    var settled = false
    var coverImage: CGImage?
    /// When the source of `coverImage` was captured; maps it to scroll displacement.
    var coverImageAt = Date.distantPast
    /// Average color of the cover source, used for gaps (just-exposed strips) instead of a dark fill.
    var coverFill: CGColor?
    /// Fresher blurred captures of scrolled panes, by tracker ID.
    var paneCovers: [Int: (image: CGImage, rect: CGRect, capturedAt: Date)] = [:]
    var layoutChanged = false
    var dirtyReasons: Set<DirtyReason> = []
    var dirtySince: Date?
    var lastScrollAt = Date.distantPast
    /// Scrolling containers from the last committed AX read.
    var scrollPanes: [ScrollPane] = []
    /// Panes scrolled since the last committed read, with their measured displacement.
    var trackers: [PaneTracker] = []
    var trackerCounter = 0
    /// Whole visible area at tracking scale, from the frame the current regions were read from.
    var trackingReference: TrackFrame?
    var trackTask: Task<Void, Never>?
    var trackLoopToken: UInt64 = 0
    var trackStats = TrackStats()
    /// Areas whose new, unscored content stays masked briefly after a mid-scroll re-read.
    var exposureHold: (areas: [CGRect], until: Date)?
    var lastCycleStart = Date.distantPast
    var retainedOCR: [TextObservation] = []
    var lastFullOCRAt = Date.distantPast

    /// Calendar automation hooks. User actions report here so a stop or indefinite pause can't be
    /// undone by the next calendar poll.
    var onUserStop: (() -> Void)?
    var onIndefinitePause: (() -> Void)?
    var onUserResume: (() -> Void)?
    /// Re-resolves a calendar-owned session's event before a timed pause resumes it.
    var revalidateCalendarResume: ((CalendarOccurrence) async -> Bool)?
    /// Set while a calendar start is checking capture access, so it doesn't count as a manual session.
    var pendingCalendarStart: CalendarOccurrence?

    var captureProblem: String?
    var captureRetryAt = Date.distantPast
    var captureBackoff: TimeInterval = 1
    var classifierProblem: String?
}

// MARK: - Setup

extension SessionController {
    func setUp() {
        refreshDisplays()
        scheduler.onScores = { [weak self] in self?.scoresArrived($0) }
        scheduler.onProblem = { [weak self] in self?.classifierProblemChanged($0) }
        scheduler.onStatsChanged = { [weak self] in
            guard let self else { return }
            self.usage = self.scheduler.stats
        }
        scheduler.onRequestLogged = { [weak self] in self?.log($0) }
        scheduler.onIdentityChanged = { [weak self] in
            guard let self else { return }
            // Old cache entries no longer match the provider identity; affected regions re-score.
            self.rebuildDecisions()
            self.render()
            self.syncClassification()
            self.log(["event": "classifier_model_changed", "provider": self.classifier.providerID])
        }
        scheduler.gateDelay = { [weak self] in self?.classificationGateDelay() }
        coverQueue.onImage = { [weak self] in self?.coverArrived($0, tag: $1) }
        paneCoverQueue.onImage = { [weak self] in self?.coverArrived($0, tag: $1) }
        Task.detached(priority: .utility) { OCRRecognizer.prewarm() }
        let pauseOK = HotKeys.shared.register(HotKeys.pause) { [weak self] in
            MainActor.assumeIsolated { self?.togglePause() }
        }
        let revealOK = HotKeys.shared.register(HotKeys.reveal) { [weak self] in
            MainActor.assumeIsolated { self?.revealUnderPointer() }
        }
        hotKeyStatus = switch (pauseOK, revealOK) {
        case (true, true): "Registered"
        case (false, false): "Unavailable (shortcuts taken by another app)"
        default: pauseOK ? "Reveal shortcut unavailable" : "Pause shortcut unavailable — use the menu bar"
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.environmentChanged("Space changed — re-reading") }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.environmentChanged("Display asleep") }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        // Scrolling over the target starts geometry tracking for the pane under the pointer,
        // before pixels are compared. Mouse-event monitors don't need Input Monitoring; if macOS
        // withholds events, a large thumbnail change starts tracking a tick later.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled() }
        }
    }

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityGranted
        if Permissions.screenRecordingGranted { screenRecordingGranted = true }
    }

    /// Also the way to resume sending after fixing a rejected or missing API key.
    func refreshClassifierHealth() {
        Task {
            classifierStatus = "Checking…"
            let health = await classifier.health()
            classifierStatus = health.label
            if health == .ready { scheduler.clearAuthBlock() }
        }
    }
}

// MARK: - User controls

extension SessionController {
    /// Start a session, or apply an edited task. Editing the task while paused stays paused.
    func start() {
        let task = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            notice = "Type what you're working on first."
            return
        }
        notice = nil
        if isActive || runState == .paused {
            // Applying a typed task to a calendar-started session is a manual takeover: the event
            // ending no longer ends it.
            let takeover = taskSource != .manual
            if task != currentTask { changeTask(to: task) }
            if takeover {
                taskSource = .manual
                log(["event": "calendar_takeover"])
            }
            return
        }
        guard runState != .requestingPermissions else { return }
        // Jev is the default, but nothing leaves the Mac until the user agrees once.
        let savedProvider = ClassifierProvider(rawValue: UserDefaults.standard.string(forKey: "classifierProvider") ?? "")
        if provider == .laya, savedProvider ?? .jev == .jev, !UserDefaults.standard.bool(forKey: Self.jevConsentKey) {
            provider = .jev
        }
        runState = .requestingPermissions
        activity = "Checking Screen Recording permission"
        Task { await beginSession(task: task) }
    }

    /// Emergency toggle (⌃⌥⌘P and the Pause button): indefinite pause, or resume from any pause.
    func togglePause() {
        if runState == .paused { resume() } else if isActive { pause() }
    }

    /// Indefinite pause. Clears every overlay immediately. Calendar auto-start also waits until
    /// the user resumes.
    func pause() {
        guard isActive || runState == .paused else { return }
        onIndefinitePause?()
        cancelTimedPause()
        if isActive {
            endWork()
            runState = .paused
        }
        activity = "Paused — nothing is covered"
        log(["event": "pause", "kind": "indefinite"])
    }

    /// Timed pause with automatic resume. A new timed pause replaces any previous deadline.
    func pause(minutes: Int) {
        guard isActive || runState == .paused else { return }
        if isActive {
            endWork()
            runState = .paused
        }
        cancelTimedPause()
        pauseToken += 1
        let token = pauseToken
        let deadline = ContinuousClock.now + .seconds(minutes * 60)
        pauseDeadline = deadline
        activity = "Paused for \(minutes) min — nothing is covered"
        // Owned by the controller, not the menu panel, so it fires with the panel closed.
        // ContinuousClock keeps counting during sleep; an elapsed deadline fires once after wake.
        autoResumeTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.autoResume(token: token)
        }
        log(["event": "pause", "kind": "timed", "minutes": minutes])
    }

    /// Converts a timed pause into an indefinite one.
    func stayPaused() {
        guard runState == .paused else { return }
        cancelTimedPause()
        activity = "Paused — nothing is covered"
        log(["event": "stay_paused"])
    }

    /// User resume (button, shortcut).
    func resume() {
        guard runState == .paused, currentTask != nil else { return }
        onUserResume?()
        resumeSession()
    }

    private func resumeSession() {
        guard runState == .paused, currentTask != nil else { return }
        cancelTimedPause()
        runState = .observing
        activity = "Resuming"
        overlay.show(displayID: selectedDisplayID)
        beginLoop()
        log(["event": "resume"])
    }

    enum StopCause {
        /// The user pressed Stop: calendar automation skips the current event(s).
        case user
        case quit
        /// The calendar event that owned the session ended, changed, or became unavailable.
        case calendar(String)
    }

    func stop(cause: StopCause = .user) {
        guard runState != .stopped else { return }
        if case .user = cause { onUserStop?() }
        cancelTimedPause()
        endWork()
        overlay.hide()
        runState = .stopped
        currentTask = nil
        sessionID = nil
        overrides.clear()
        scoreCache.removeAll()
        coverage = nil
        taskSource = .manual
        switch cause {
        case .user, .quit:
            activity = "Stopped"
            log(["event": "stop"])
        case .calendar(let reason):
            activity = "Calendar session ended: \(reason)"
            log(["event": "calendar_end", "reason": reason])
        }
    }

    func reveal(regionID: String) {
        guard let region = regions.first(where: { $0.id == regionID }) else { return }
        overrides.reveal(revision: taskRevision, fingerprint: region.fingerprint)
        notice = "Region #\(region.number) revealed for 10 minutes (this task, this content)."
        rebuildDecisions()
        render()
        log(["event": "reveal", "region": region.number])
    }

    func unreveal(regionID: String) {
        guard let region = regions.first(where: { $0.id == regionID }) else { return }
        overrides.unreveal(revision: taskRevision, fingerprint: region.fingerprint)
        rebuildDecisions()
        render()
    }

    func revealExpiry(for region: ScreenRegion) -> Date? {
        overrides.expiry(revision: taskRevision, fingerprint: region.fingerprint)
    }

    /// Reveals the smallest covered region under the mouse pointer, without clicking the
    /// click-through overlay.
    func revealUnderPointer() {
        guard isActive else { return }
        let point = Geometry.appKitPointToQuartz(NSEvent.mouseLocation)
        let hits = regions.filter { currentRect($0.rect)?.contains(point) == true }
        let covered = hits.filter { !visibleRegionIDs.contains($0.id) }
        guard let region = (covered.isEmpty ? hits : covered).min(by: { $0.rect.area < $1.rect.area }) else {
            notice = "No region under the pointer. Text-free areas can't be revealed individually; pause instead."
            return
        }
        reveal(regionID: region.id)
    }

    /// One-time notice before any screen text goes to a hosted classifier.
    func confirmCloudConsent() -> Bool {
        if UserDefaults.standard.bool(forKey: Self.jevConsentKey) { return true }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Send screen text to Jev?"
        alert.informativeText = """
            Jev runs on TypeSafe's servers (api.typesafe.ai). While Heads Down is active, it sends \
            the text of each region it reads from the front window, plus the app name, window \
            title, and your task, for scoring. If you turn on Google Calendar auto-start, the task \
            can come from your current calendar event (sanitized title and agenda). Screenshots are \
            never sent. Usage is billed to the \
            API key in your .env.

            Laya (local) keeps everything on this Mac but is less accurate. You can switch any \
            time in the menu-bar panel.
            """
        alert.addButton(withTitle: "Use Jev")
        alert.addButton(withTitle: "Use Laya (local)")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        if accepted { UserDefaults.standard.set(true, forKey: Self.jevConsentKey) }
        log(["event": "cloud_consent", "accepted": accepted])
        return accepted
    }

    private func classifierChanged() {
        scheduler.replace(classifier: Self.makeClassifier(provider))
        classifierProblem = nil
        updateRunState()
        rebuildDecisions()
        render()
        syncClassification()
        refreshClassifierHealth()
        log(["event": "classifier", "provider": classifier.providerID])
    }

    func deleteDiagnostics() {
        DiagnosticsLog.shared.deleteAll()
        notice = "Diagnostics log deleted."
    }

    var diagnosticsPath: String { DiagnosticsLog.shared.url.path }
}

// MARK: - Session lifecycle

extension SessionController {
    private func beginSession(task: String) async {
        do {
            _ = try await capturer.refreshContent(force: true)
            screenRecordingGranted = true
        } catch {
            screenRecordingGranted = false
            Permissions.requestScreenRecording()
            runState = .stopped
            activity = "Screen Recording permission needed"
            notice = "Allow Heads Down in System Settings → Privacy & Security → Screen & System Audio "
                + "Recording, then press Start again. macOS may require quitting and reopening Heads Down."
            return
        }
        guard runState == .requestingPermissions else { return }
        if !Permissions.accessibilityGranted {
            Permissions.requestAccessibility()
            notice = "Accessibility not granted: running OCR-only. Grant it in System Settings for structured reads."
        }
        accessibilityGranted = Permissions.accessibilityGranted
        activate(task: task, source: .manual)
    }

    /// Starts the loop for `task`. Callers have already checked permissions and consent; this never
    /// prompts, so the calendar path can use it. `taskDraft` is left alone.
    func activate(task: String, source: TaskSource) {
        cancelTimedPause()
        sessionID = String(UUID().uuidString.prefix(8))
        currentTask = task
        taskSource = source
        taskRevision += 1
        overrides.clear()
        scoreCache.removeAll()
        scheduler.resetStats()
        scheduler.clearAuthBlock()
        runState = .observing
        activity = "Looking for the front window"
        overlay.show(displayID: selectedDisplayID)
        beginLoop()
        refreshClassifierHealth()
        log(["event": "start", "ax": accessibilityGranted, "mode": mode.rawValue,
             "source": source == .manual ? "manual" : "calendar"])
    }

    /// A new task invalidates every decision, but not the screen reading: regions stay, their
    /// scores become pending (covered), and only classification reruns.
    func changeTask(to task: String) {
        currentTask = task
        taskRevision += 1
        scoreCache.removeAll()
        overrides.clear()
        retainedWindows = [:]
        rebuildDecisions()
        render()
        syncClassification()
        activity = runState == .paused ? "Task updated — still paused" : "Task changed — rechecking"
        log(["event": "task_changed"])
    }

    /// A timed pause ending. A calendar-owned session is resumed only if its event is still current
    /// and eligible; it's never resurrected after the event ended or was cancelled.
    private func autoResume(token: UInt64) {
        guard token == pauseToken, runState == .paused, pauseDeadline != nil, currentTask != nil else { return }
        guard let occurrence = taskSource.occurrence, let revalidate = revalidateCalendarResume else {
            log(["event": "auto_resume"])
            resumeSession()
            return
        }
        Task {
            let stillCurrent = await revalidate(occurrence)
            guard token == self.pauseToken, self.runState == .paused, self.taskSource.occurrence == occurrence else {
                return
            }
            if stillCurrent {
                self.log(["event": "auto_resume"])
                self.resumeSession()
            } else {
                self.stop(cause: .calendar("event no longer current"))
            }
        }
    }

    func cancelTimedPause() {
        autoResumeTask?.cancel()
        autoResumeTask = nil
        pauseToken += 1
        pauseDeadline = nil
    }

    func beginLoop() {
        sessionGeneration += 1
        let session = sessionGeneration
        target = nil
        invalidateAll()
        lastCycleStart = .distantPast
        captureProblem = nil
        captureRetryAt = .distantPast
        captureBackoff = 1
        classifierProblem = nil
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.sessionGeneration == session else { return }
                await self.tick(session: session)
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Cancels the loop and clears overlays immediately. Late results are rejected because the
    /// session generation no longer matches. Scores and reveals are kept for resume.
    func endWork() {
        sessionGeneration += 1
        loopTask?.cancel()
        loopTask = nil
        scheduler.stopAll()
        retainedWindows = [:]
        invalidateAll()
        target = nil
        captureProblem = nil
        classifierProblem = nil
    }

    /// Drops all geometry-dependent state and clears overlays right away. The lane task is
    /// cancelled but stays registered until it actually finishes.
    func invalidateAll() {
        laneTask?.cancel()
        activeCycleID = 0
        regions = []
        decisions = [:]
        changedRegionIDs = []
        visibleRegionIDs = []
        baseline = nil
        latestThumb = nil
        motionStreak = []
        settled = false
        coverImage = nil
        coverImageAt = .distantPast
        coverFill = nil
        paneCovers = [:]
        coverQueue.cancelAll()
        paneCoverQueue.cancelAll()
        coverStatus = "No cover image yet — neutral placeholder"
        layoutChanged = false
        stopTracking()
        scrollPanes = []
        trackingReference = nil
        exposureHold = nil
        retainedOCR = []
        lastFullOCRAt = .distantPast
        controlRects = []
        dirtyReasons = [.newTarget]
        dirtySince = Date()
        renderedCover = "None"
        overlay.clear()
        // Inputs from the old geometry that haven't been sent yet are no longer useful.
        syncClassification()
    }

    private func environmentChanged(_ reason: String) {
        guard isActive else { return }
        invalidateAll()
        target = nil
        activity = reason
    }

    private func screensChanged() {
        refreshDisplays()
        if !displays.contains(where: { $0.id == selectedDisplayID }) { selectedDisplayID = CGMainDisplayID() }
        overlay.screenParametersChanged()
        environmentChanged("Display arrangement changed — re-reading")
    }

    private func displaySelectionChanged() {
        guard isActive else { return }
        retainedWindows = [:]
        invalidateAll()
        target = nil
        overlay.show(displayID: selectedDisplayID)
    }

    private func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = Geometry.screenID(screen) else { return nil }
            return DisplayChoice(id: id, name: screen.localizedName)
        }
    }

    func displayName(_ id: CGDirectDisplayID) -> String {
        displays.first { $0.id == id }?.name ?? "Display \(id)"
    }

    func updateRunState() {
        guard isActive else { return }
        if captureProblem != nil || classifierProblem != nil {
            runState = .degraded
        } else {
            runState = laneTask == nil ? .observing : .processing
        }
    }

    private func modeChanged() {
        render()
        log(["event": "mode", "mode": mode.rawValue])
    }

    private func userScrolled() {
        guard isActive, let target else { return }
        let point = Geometry.appKitPointToQuartz(NSEvent.mouseLocation)
        guard target.visibleRect.contains(point), !target.occluders.contains(where: { $0.rect.contains(point) })
        else { return }
        let now = Date()
        lastScrollAt = now
        dirtyReasons.insert(.scroll)
        if dirtySince == nil { dirtySince = lastScrollAt }
        scrollStarted(in: pane(at: point, target: target), now: now)
    }

    func log(_ record: [String: Any]) {
        guard diagnosticsEnabled else { return }
        var record = record
        record["session"] = sessionID ?? NSNull()
        DiagnosticsLog.shared.append(record)
    }
}
