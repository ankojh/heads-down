import AppKit
import Combine

struct DisplayChoice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// Runs the autonomous loop once the user starts a task:
///
///   tick (every 400 ms): locate the target window → small capture → change detection
///     → hide overlays on changed areas immediately → start a cycle when content settles
///   cycle (at most one in flight): capture → AX + OCR → merge → segment → reuse cached scores
///     → classify changed regions in one batch → re-check generations → policy → overlays
///
/// This is rule-based orchestration of local tools, not an LLM planner. Every result is checked
/// against the session, task revision, cycle ID, and window geometry before it is shown, so pausing,
/// stopping, or a task/window change can never be undone by a late result.
@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    static let tickInterval: Duration = .milliseconds(400)
    static let minCycleInterval: TimeInterval = 1.0
    static let unsettledCycleInterval: TimeInterval = 3.0
    static let maxUnsettledWait: TimeInterval = 3.0
    static let settledChangeFraction = 0.02
    static let maxClassifierBackoff: TimeInterval = 30
    static let maxCaptureBackoff: TimeInterval = 10

    // MARK: - Published state

    @Published var taskDraft = ""
    @Published private(set) var currentTask: String?
    @Published private(set) var taskRevision = 0
    @Published private(set) var sessionID: String?
    @Published var mode: CoverMode = .observe {
        didSet { if oldValue != mode { modeChanged() } }
    }
    @Published var showBoxes = true {
        didSet { render() }
    }
    @Published private(set) var runState: RunState = .stopped
    @Published private(set) var activity = "Idle"
    @Published private(set) var regions: [ScreenRegion] = []
    @Published private(set) var decisions: [String: RegionDecision] = [:]
    @Published private(set) var staleRegionIDs: Set<String> = []
    @Published private(set) var coverage: Coverage?
    @Published private(set) var lastTimings: CycleTimings?
    @Published private(set) var classifierStatus = "Not checked"
    @Published private(set) var screenRecordingGranted = Permissions.screenRecordingGranted
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var displays: [DisplayChoice] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID() {
        didSet { if oldValue != selectedDisplayID { displaySelectionChanged() } }
    }
    @Published var selectedRegionID: String?
    @Published private(set) var hotKeyStatus = "Not registered"
    @Published private(set) var notice: String?
    @Published var diagnosticsEnabled = UserDefaults.standard.object(forKey: "diagnosticsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(diagnosticsEnabled, forKey: "diagnosticsEnabled") }
    }

    var isActive: Bool { [.observing, .processing, .degraded].contains(runState) }
    var classifierEndpoint: String { classifier.endpointDescription }

    var menuBarSymbol: String {
        switch runState {
        case .stopped: return "eye"
        case .requestingPermissions: return "lock.shield"
        case .paused: return "pause.circle"
        case .degraded: return "exclamationmark.triangle"
        case .observing, .processing: return "eye.circle.fill"
        }
    }

    // MARK: - Private state

    private let classifier: DistractionClassifier = LayaClient()
    private let capturer = ScreenCapturer()
    private let overlay = OverlayController()
    private let overrides = RevealOverrides()
    private var scoreCache = ScoreCache(limit: 1000)
    private var observers: [NSObjectProtocol] = []

    private var loopTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var cycleCounter: UInt64 = 0
    private var activeCycleID: UInt64 = 0

    private var target: TargetWindow?
    /// Thumbnail matching the frame the current regions came from.
    private var baseline: Thumbnail?
    private var latestThumb: Thumbnail?
    private var latestThumbAt = Date.distantPast
    private var unsettledSince: Date?
    private var changeDetectedAt: Date?
    private var needsAnalysis = true
    private var lastCycleStart = Date.distantPast

    /// Only the most recent frame is kept, for blur crops. Released on invalidation and stop.
    private var lastSnapshot: ScreenSnapshot?
    private var blurCache: [String: CGImage] = [:]

    private var captureProblem: String?
    private var captureRetryAt = Date.distantPast
    private var captureBackoff: TimeInterval = 1
    private var classifierProblem: String?
    private var classifierRetryAt = Date.distantPast
    private var classifierBackoff: TimeInterval = 2

    private struct CycleContext {
        let id: UInt64
        let session: UInt64
        let revision: Int
        let task: String
        let target: TargetWindow
        let changeAt: Date?
    }
}

// MARK: - Setup

extension SessionController {
    func setUp() {
        refreshDisplays()
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
    }

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityGranted
        if Permissions.screenRecordingGranted { screenRecordingGranted = true }
    }

    func refreshClassifierHealth() {
        Task {
            classifierStatus = "Checking…"
            classifierStatus = await classifier.health().label
        }
    }

}

// MARK: - User controls

extension SessionController {
    func start() {
        let task = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            notice = "Type what you're working on first."
            return
        }
        notice = nil
        if isActive || runState == .paused {
            if task != currentTask { changeTask(to: task) }
            if runState == .paused { resume() }
            return
        }
        guard runState != .requestingPermissions else { return }
        runState = .requestingPermissions
        activity = "Checking Screen Recording permission"
        Task { await beginSession(task: task) }
    }

    func togglePause() {
        if runState == .paused { resume() } else if isActive { pause() }
    }

    func pause() {
        guard isActive else { return }
        endWork()
        runState = .paused
        activity = "Paused — nothing is covered"
        log(["event": "pause"])
    }

    func resume() {
        guard runState == .paused, currentTask != nil else { return }
        runState = .observing
        activity = "Resuming"
        overlay.show(displayID: selectedDisplayID)
        beginLoop()
        log(["event": "resume"])
    }

    func stop() {
        guard runState != .stopped else { return }
        endWork()
        overlay.hide()
        runState = .stopped
        currentTask = nil
        sessionID = nil
        overrides.clear()
        scoreCache.removeAll()
        coverage = nil
        activity = "Stopped"
        log(["event": "stop"])
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
        if mode == .blur { Task { await prepareBlurCrops(); render() } }
    }

    func revealExpiry(for region: ScreenRegion) -> Date? {
        overrides.expiry(revision: taskRevision, fingerprint: region.fingerprint)
    }

    /// Reveals the smallest covered region under the mouse pointer. Works without clicking the
    /// click-through overlay.
    func revealUnderPointer() {
        guard isActive else { return }
        let point = Geometry.appKitPointToQuartz(NSEvent.mouseLocation)
        let hits = regions.filter { !staleRegionIDs.contains($0.id) && $0.rect.contains(point) }
        let covered = hits.filter { decisions[$0.id]?.action != .leave }
        guard let region = (covered.isEmpty ? hits : covered).min(by: { $0.rect.area < $1.rect.area }) else {
            notice = "No region under the pointer."
            return
        }
        reveal(regionID: region.id)
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

        sessionID = String(UUID().uuidString.prefix(8))
        currentTask = task
        taskRevision += 1
        overrides.clear()
        scoreCache.removeAll()
        runState = .observing
        activity = "Looking for the front window"
        overlay.show(displayID: selectedDisplayID)
        beginLoop()
        refreshClassifierHealth()
        log(["event": "start", "ax": accessibilityGranted])
    }

    private func changeTask(to task: String) {
        currentTask = task
        taskRevision += 1
        scoreCache.removeAll()
        overrides.clear()
        // A new task invalidates every decision, even if the screen text is unchanged.
        invalidateAll()
        activity = "Task changed — rechecking"
        log(["event": "task_changed"])
    }

    private func beginLoop() {
        sessionGeneration += 1
        let session = sessionGeneration
        target = nil
        invalidateAll()
        unsettledSince = nil
        lastCycleStart = .distantPast
        captureProblem = nil
        captureRetryAt = .distantPast
        captureBackoff = 1
        classifierProblem = nil
        classifierRetryAt = .distantPast
        classifierBackoff = 2
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.sessionGeneration == session else { return }
                await self.tick(session: session)
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Cancels all work and clears overlays immediately. Late results are rejected because the
    /// session generation no longer matches.
    private func endWork() {
        sessionGeneration += 1
        loopTask?.cancel()
        loopTask = nil
        invalidateAll()
        target = nil
        captureProblem = nil
        classifierProblem = nil
    }

    /// Drops all geometry-dependent state and clears overlays right away.
    private func invalidateAll() {
        cycleTask?.cancel()
        cycleTask = nil
        activeCycleID = 0
        regions = []
        decisions = [:]
        staleRegionIDs = []
        blurCache = [:]
        lastSnapshot = nil
        baseline = nil
        latestThumb = nil
        needsAnalysis = true
        changeDetectedAt = Date()
        overlay.clear()
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

    private func displayName(_ id: CGDirectDisplayID) -> String {
        displays.first { $0.id == id }?.name ?? "Display \(id)"
    }

    private func updateRunState() {
        guard isActive else { return }
        if captureProblem != nil || classifierProblem != nil {
            runState = .degraded
        } else {
            runState = cycleTask == nil ? .observing : .processing
        }
    }

}

// MARK: - Tick: window tracking and change detection

extension SessionController {
    private func tick(session: UInt64) async {
        guard session == sessionGeneration, isActive else { return }
        switch WindowLocator.locate(displayID: selectedDisplayID, ignoring: overlay.windowIDs) {
        case .failure(let skip):
            if target != nil || coverage?.skipReason != skip.message {
                invalidateAll()
                target = nil
                coverage = Coverage(displayName: displayName(selectedDisplayID), skipReason: skip.message)
                activity = skip.message
            }
            return
        case .success(let found):
            if let current = target, current.sameGeometry(as: found) {
                target = found
            } else {
                let hadTarget = target != nil
                invalidateAll()
                target = found
                coverage = Coverage(
                    appName: found.appName, windowTitle: found.title, windowID: found.windowID,
                    displayName: displayName(found.displayID), bounds: found.visibleRect,
                    skippedAreas: describeSkipped(found))
                unsettledSince = Date()
                activity = hadTarget ? "Window changed — waiting for it to settle" : "Found \(found.appName) window"
            }
        }

        guard let current = target, Date() >= captureRetryAt else { return }
        let thumb: Thumbnail
        do {
            let (image, _) = try await capturer.capture(
                rect: current.visibleRect, displayID: current.displayID, pixelsPerPoint: thumbScale(current))
            guard let made = Thumbnail(image: image, rect: current.visibleRect) else { return }
            thumb = made
        } catch {
            if session == sessionGeneration, isActive { handleCaptureFailure(error) }
            return
        }
        guard session == sessionGeneration, isActive, let now = target, now.sameGeometry(as: current) else { return }
        clearCaptureProblem()

        let previous = latestThumb
        latestThumb = thumb
        latestThumbAt = Date()
        if let previous, thumb.diff(against: previous).changedFraction < Self.settledChangeFraction {
            unsettledSince = nil
        } else if unsettledSince == nil {
            unsettledSince = Date()
        }

        if let baseline {
            let diff = thumb.diff(against: baseline)
            if diff.changedRects.isEmpty {
                if !staleRegionIDs.isEmpty {
                    staleRegionIDs = []
                    render()
                }
            } else {
                if changeDetectedAt == nil { changeDetectedAt = Date() }
                needsAnalysis = true
                let stale = staleIDs(for: diff.changedRects)
                if stale != staleRegionIDs {
                    staleRegionIDs = stale
                    render()
                }
            }
        }
        maybeStartCycle(current)
    }

    private func maybeStartCycle(_ current: TargetWindow) {
        guard cycleTask == nil, currentTask != nil else { return }
        let retryDue = classifierProblem != nil && Date() >= classifierRetryAt
            && regions.contains { scoreCache[cacheKey($0, revision: taskRevision)] == nil }
        guard needsAnalysis || retryDue else { return }
        let settled = unsettledSince == nil
        let interval = settled ? Self.minCycleInterval : Self.unsettledCycleInterval
        guard Date().timeIntervalSince(lastCycleStart) >= interval else { return }
        if !settled, let since = unsettledSince, Date().timeIntervalSince(since) < Self.maxUnsettledWait {
            activity = "Waiting for content to settle"
            return
        }
        startCycle(target: current)
    }

    private func staleIDs(for changed: [CGRect]) -> Set<String> {
        Set(regions.filter { region in
            let inner = region.rect.insetBy(dx: 2, dy: 2)
            return changed.contains { $0.intersects(inner) }
        }.map(\.id))
    }

    private func thumbScale(_ target: TargetWindow) -> CGFloat {
        CGFloat(Thumbnail.width) / max(1, target.visibleRect.width)
    }

}

// MARK: - Cycle: read, group, classify, apply

extension SessionController {
    private func startCycle(target: TargetWindow) {
        guard let task = currentTask else { return }
        cycleCounter += 1
        let context = CycleContext(
            id: cycleCounter, session: sessionGeneration, revision: taskRevision, task: task,
            target: target, changeAt: changeDetectedAt)
        activeCycleID = context.id
        lastCycleStart = Date()
        needsAnalysis = false
        changeDetectedAt = nil
        cycleTask = Task { [weak self] in
            await self?.runCycle(context)
            guard let self, self.activeCycleID == context.id else { return }
            self.cycleTask = nil
            self.updateRunState()
        }
        updateRunState()
    }

    private func isCurrent(_ context: CycleContext) -> Bool {
        guard !Task.isCancelled, isActive, context.session == sessionGeneration,
              context.revision == taskRevision, context.id == activeCycleID,
              let target, target.sameGeometry(as: context.target)
        else { return false }
        return true
    }

    // swiftlint:disable:next function_body_length
    private func runCycle(_ context: CycleContext) async {
        var timings = CycleTimings(cycleID: context.id)
        let started = Date()
        if let changeAt = context.changeAt { timings.queueMs = started.timeIntervalSince(changeAt) * 1000 }
        let target = context.target
        activity = "Reading screen"

        // 1. Capture a change-detection baseline and the full frame back to back.
        let captureStart = Date()
        let scale = Geometry.backingScale(for: target.displayID)
        let baseThumb: Thumbnail
        let snapshot: ScreenSnapshot
        do {
            let (small, _) = try await capturer.capture(
                rect: target.visibleRect, displayID: target.displayID, pixelsPerPoint: thumbScale(target))
            let (full, geometry) = try await capturer.capture(
                rect: target.visibleRect, displayID: target.displayID, pixelsPerPoint: scale)
            guard let thumb = Thumbnail(image: small, rect: target.visibleRect) else { return }
            baseThumb = thumb
            snapshot = ScreenSnapshot(cycleID: context.id, capturedAt: Date(), geometry: geometry, image: full)
        } catch {
            if isCurrent(context) { handleCaptureFailure(error) }
            return
        }
        timings.captureMs = elapsedMs(since: captureStart)
        guard isCurrent(context) else { return }
        clearCaptureProblem()

        // 2. Accessibility (bounded) and OCR in parallel, off the main actor.
        let axAllowed = Permissions.accessibilityGranted
        accessibilityGranted = axAllowed
        activity = axAllowed ? "Reading accessibility tree + OCR" : "Running OCR (no accessibility)"
        let cycleID = context.id
        let axJob = Task.detached(priority: .userInitiated) { () -> (AXReadResult, Double) in
            let start = Date()
            let result = axAllowed
                ? AccessibilityReader.read(target: target, generation: cycleID)
                : AXReadResult(status: "Accessibility not granted")
            return (result, elapsedMs(since: start))
        }
        let ocrJob = Task.detached(priority: .userInitiated) { () -> (Result<[TextObservation], Error>, Double) in
            let start = Date()
            let result = Result {
                try OCRRecognizer.recognize(
                    image: snapshot.image, geometry: snapshot.geometry, windowID: target.windowID, generation: cycleID)
            }
            return (result, elapsedMs(since: start))
        }
        let (axResult, axMs) = await axJob.value
        let (ocrResult, ocrMs) = await ocrJob.value
        timings.axMs = axMs
        timings.ocrMs = ocrMs
        guard isCurrent(context) else { return }
        var notes: [String] = []
        let ocrLines: [TextObservation]
        switch ocrResult {
        case .success(let lines): ocrLines = lines
        case .failure(let error):
            ocrLines = []
            notes.append("OCR failed: \(error.localizedDescription)")
        }

        // 3. Merge sources and group into regions.
        activity = "Grouping text into regions"
        let groupStart = Date()
        let occluderRects = target.occluders.map(\.rect)
        let (segmentation, stats) = await Task.detached(priority: .userInitiated) {
            let (merged, stats) = ObservationMerger.merge(
                accessibility: axResult.texts, ocr: ocrLines, visibleRect: target.visibleRect, occluders: occluderRects)
            let output = Segmenter.segment(SegmentationInput(
                observations: merged, containers: axResult.containers, visibleRect: target.visibleRect,
                occluders: occluderRects, appName: target.appName, windowTitle: target.title,
                windowID: target.windowID))
            return (output, stats)
        }.value
        timings.groupMs = elapsedMs(since: groupStart)
        timings.axNodes = axResult.nodesVisited
        timings.axTexts = axResult.texts.count
        timings.ocrLines = ocrLines.count
        timings.regionCount = segmentation.regions.count
        guard isCurrent(context) else { return }

        regions = segmentation.regions
        baseline = baseThumb
        lastSnapshot = snapshot
        blurCache = [:]
        staleRegionIDs = changedSince(baseThumb, capturedAt: snapshot.capturedAt)
        if let selected = selectedRegionID, !regions.contains(where: { $0.id == selected }) { selectedRegionID = nil }
        updateCoverage(target: target, ax: axResult, stats: stats, segmentation: segmentation, notes: notes)
        rebuildDecisions()
        render()

        // 4. Classify only regions without a cached score for this task/provider/question/content.
        var errorCategory: String?
        let pending = regions.filter { scoreCache[cacheKey($0, revision: context.revision)] == nil }
        timings.cachedCount = regions.count - pending.count
        if !pending.isEmpty, Date() >= classifierRetryAt {
            activity = "Checking \(pending.count) changed region\(pending.count == 1 ? "" : "s")"
            let classifyStart = Date()
            do {
                let inputs = pending.map { ClassifierInput(app: $0.appName, title: $0.windowTitle, text: $0.text) }
                let scores = try await classifier.classify(task: context.task, regions: inputs)
                timings.classifyMs = elapsedMs(since: classifyStart)
                guard context.session == sessionGeneration, context.revision == taskRevision else { return }
                for (region, score) in zip(pending, scores) {
                    if let value = score.pDistracting {
                        scoreCache.set(cacheKey(region, revision: context.revision), value)
                    }
                }
                timings.classifiedCount = scores.filter { $0.pDistracting != nil }.count
                classifierProblem = nil
                classifierBackoff = 2
                classifierStatus = "Ready"
            } catch {
                timings.classifyMs = elapsedMs(since: classifyStart)
                guard context.session == sessionGeneration else { return }
                let described = (error as? ClassifierError)?.errorDescription ?? error.localizedDescription
                errorCategory = (error as? ClassifierError)?.category ?? "other"
                classifierProblem = "Paused covering: \(described)"
                classifierRetryAt = Date().addingTimeInterval(classifierBackoff)
                classifierStatus = "Unavailable (\(described)); retry in \(Int(classifierBackoff)) s"
                classifierBackoff = min(classifierBackoff * 2, Self.maxClassifierBackoff)
            }
        }
        guard isCurrent(context) else { return }

        // 5. Re-check geometry against the newest thumbnail, then apply.
        staleRegionIDs = changedSince(baseThumb, capturedAt: snapshot.capturedAt)
        rebuildDecisions()
        if mode == .blur {
            let blurStart = Date()
            await prepareBlurCrops()
            timings.blurMs = elapsedMs(since: blurStart)
            guard isCurrent(context) else { return }
        }
        render()

        timings.totalMs = elapsedMs(since: started)
        timings.captureToOverlayMs = elapsedMs(since: snapshot.capturedAt)
        timings.changeToOverlayMs = context.changeAt.map { elapsedMs(since: $0) }
        lastTimings = timings
        activity = classifierProblem ?? summaryActivity()
        logCycle(context: context, timings: timings, axUsed: stats.axKept > 0, error: errorCategory)
    }

    /// Regions whose area changed between their capture and the newest thumbnail.
    private func changedSince(_ base: Thumbnail, capturedAt: Date) -> Set<String> {
        guard let latest = latestThumb, latestThumbAt > capturedAt else { return [] }
        let diff = latest.diff(against: base)
        if !diff.changedRects.isEmpty {
            needsAnalysis = true
            if changeDetectedAt == nil { changeDetectedAt = latestThumbAt }
        }
        return staleIDs(for: diff.changedRects)
    }

    private func cacheKey(_ region: ScreenRegion, revision: Int) -> String {
        ScoreCache.key(
            revision: revision, provider: classifier.providerID, question: classifier.questionVersion,
            input: region.classifierFingerprint)
    }

    private func handleCaptureFailure(_ error: Error) {
        invalidateAll()
        captureRetryAt = Date().addingTimeInterval(captureBackoff)
        captureBackoff = min(captureBackoff * 2, Self.maxCaptureBackoff)
        let permissionHint = Permissions.screenRecordingGranted ? "" : " (Screen Recording may be off)"
        captureProblem = "Screen capture unavailable\(permissionHint): \(error.localizedDescription)"
        activity = captureProblem ?? ""
        updateRunState()
        Task { await capturer.invalidate() }
        log(["event": "capture_error", "error": String(describing: type(of: error))])
    }

    private func clearCaptureProblem() {
        guard captureProblem != nil else { return }
        captureProblem = nil
        captureBackoff = 1
        updateRunState()
    }

}

// MARK: - Policy and rendering

extension SessionController {
    private func rebuildDecisions() {
        let cycleID = lastSnapshot?.cycleID ?? 0
        var result: [String: RegionDecision] = [:]
        for region in regions {
            let score = scoreCache[cacheKey(region, revision: taskRevision)]
            let revealed = overrides.isRevealed(revision: taskRevision, fingerprint: region.fingerprint)
            let applied = Policy.applied(
                score: score, mode: mode, geometryUncertain: region.geometryUncertain, revealed: revealed)
            result[region.id] = RegionDecision(
                regionID: region.id, fingerprint: region.fingerprint, taskRevision: taskRevision,
                cycleID: cycleID, providerID: classifier.providerID, questionVersion: classifier.questionVersion,
                pDistracting: score, tier: Policy.tier(for: score), action: applied.action,
                overridden: revealed, policyNote: applied.note, decidedAt: Date())
        }
        decisions = result
    }

    private func modeChanged() {
        rebuildDecisions()
        render()
        if mode == .blur {
            Task {
                await prepareBlurCrops()
                render()
            }
        }
        log(["event": "mode", "mode": mode.rawValue])
    }

    private func prepareBlurCrops() async {
        guard mode == .blur, let snapshot = lastSnapshot else { return }
        let jobs = regions
            .filter { decisions[$0.id]?.action == .blur && blurCache[$0.id] == nil }
            .map { ($0.id, $0.rect) }
        guard !jobs.isEmpty else { return }
        let rendered = await Task.detached(priority: .userInitiated) {
            jobs.compactMap { id, rect in
                BlurRenderer.blurredCrop(of: snapshot.image, geometry: snapshot.geometry, rect: rect).map { (id, $0) }
            }
        }.value
        guard lastSnapshot?.cycleID == snapshot.cycleID else { return }
        for (id, image) in rendered { blurCache[id] = image }
    }

    private func render() {
        guard isActive else {
            overlay.clear()
            return
        }
        let items: [OverlayItem] = regions.compactMap { region in
            guard !staleRegionIDs.contains(region.id) else { return nil }
            let decision = decisions[region.id]
            let cover: OverlayItem.Cover
            switch decision?.action ?? .leave {
            case .leave: cover = .none
            case .dim: cover = .dim
            case .blur: cover = blurCache[region.id].map { .blur($0) } ?? .none
            }
            if !showBoxes, case .none = cover { return nil }
            return OverlayItem(
                rect: region.rect, number: region.number, cover: cover, showBox: showBoxes,
                label: badgeLabel(region, decision), color: tierColor(decision),
                uncertain: region.geometryUncertain)
        }
        overlay.update(displayID: selectedDisplayID, items: items)
    }

    private func badgeLabel(_ region: ScreenRegion, _ decision: RegionDecision?) -> String {
        var label = "#\(region.number)"
        if let score = decision?.pDistracting { label += String(format: " %.2f", score) } else { label += " ?" }
        if decision?.overridden == true { label += " revealed" }
        return label
    }

    private func tierColor(_ decision: RegionDecision?) -> NSColor {
        guard let decision, decision.pDistracting != nil else { return .systemGray }
        switch decision.tier {
        case .leave: return .systemGreen
        case .dim: return .systemOrange
        case .blur: return .systemRed
        }
    }

    private func summaryActivity() -> String {
        let visible = regions.filter { !staleRegionIDs.contains($0.id) }
        let actions = visible.compactMap { decisions[$0.id]?.action }
        let dimmed = actions.filter { $0 == .dim }.count
        let blurred = actions.filter { $0 == .blur }.count
        let unscored = visible.filter { decisions[$0.id]?.pDistracting == nil }.count
        var parts = ["Watching \(visible.count) region\(visible.count == 1 ? "" : "s")"]
        if dimmed > 0 { parts.append("\(dimmed) dimmed") }
        if blurred > 0 { parts.append("\(blurred) blurred") }
        if unscored > 0 { parts.append("\(unscored) unscored") }
        return parts.joined(separator: " · ")
    }

}

// MARK: - Coverage and diagnostics

extension SessionController {
    private func describeSkipped(_ target: TargetWindow) -> [String] {
        target.occluders.map { "Skipped: under \($0.owner) (layer \($0.layer)) — \($0.rect.shortDescription)" }
            + target.ignoredOverlays.map {
                "Ignored overlay from \($0.owner) (layer \($0.layer)), assumed transparent — \($0.rect.shortDescription)"
            }
    }

    private func updateCoverage(
        target: TargetWindow, ax: AXReadResult, stats: MergeStats, segmentation: SegmentationOutput, notes: [String]
    ) {
        var info = Coverage(
            appName: target.appName, windowTitle: target.title, windowID: target.windowID,
            displayName: displayName(target.displayID), bounds: target.visibleRect)
        info.readMode = stats.axKept > 0 ? "Accessibility + OCR" : "OCR only"
        info.axStatus = "\(ax.status) · \(ax.nodesVisited) nodes · \(ax.texts.count) texts "
            + "(\(stats.axKept) confirmed visible) · \(ax.containers.count) containers"
        info.skippedAreas = describeSkipped(target)
        var allNotes = notes
        allNotes.append("OCR lines: \(stats.ocrInput) (\(stats.ocrDuplicates) duplicated AX text, \(stats.ocrKept) kept)")
        if stats.axUnconfirmed > 0 {
            allNotes.append("\(stats.axUnconfirmed) AX texts had no visible OCR text under them — skipped as possibly hidden")
        }
        if segmentation.containerGroups == 0 {
            allNotes.append("No AX containers used: boxes cover text blocks only, not card/image backgrounds")
        } else {
            allNotes.append("\(segmentation.containerGroups) regions use AX container bounds")
        }
        if segmentation.droppedTiny > 0 { allNotes.append("\(segmentation.droppedTiny) tiny text blocks ignored") }
        if segmentation.droppedOverCap > 0 {
            allNotes.append("\(segmentation.droppedOverCap) blocks over the \(Segmenter.maxRegions)-region cap ignored")
        }
        info.notes = allNotes
        coverage = info
    }

    private func log(_ record: [String: Any]) {
        guard diagnosticsEnabled else { return }
        var record = record
        record["session"] = sessionID ?? NSNull()
        DiagnosticsLog.shared.append(record)
    }

    private func logCycle(context: CycleContext, timings: CycleTimings, axUsed: Bool, error: String?) {
        guard diagnosticsEnabled else { return }
        let regionRecords: [[String: Any]] = regions.map { region in
            let decision = decisions[region.id]
            return [
                "n": region.number,
                "src": region.sourceLabel,
                "chars": region.text.count,
                "p": decision?.pDistracting ?? NSNull(),
                "action": decision?.action.rawValue ?? "leave",
                "uncertain": region.geometryUncertain,
                "stale": staleRegionIDs.contains(region.id),
            ]
        }
        let timingRecord: [String: Any] = [
            "queue": timings.queueMs ?? NSNull(), "capture": timings.captureMs, "ax": timings.axMs,
            "ocr": timings.ocrMs, "group": timings.groupMs, "classify": timings.classifyMs ?? NSNull(),
            "blur": timings.blurMs ?? NSNull(), "cycle": timings.totalMs,
            "capture_to_overlay": timings.captureToOverlayMs, "change_to_overlay": timings.changeToOverlayMs ?? NSNull(),
        ]
        log([
            "event": "cycle", "cycle": context.id, "task_rev": context.revision, "mode": mode.rawValue,
            "read_mode": axUsed ? "ax+ocr" : "ocr", "regions": timings.regionCount,
            "classified": timings.classifiedCount, "cached": timings.cachedCount, "ax_nodes": timings.axNodes,
            "ax_texts": timings.axTexts, "ocr_lines": timings.ocrLines, "ms": timingRecord,
            "decisions": regionRecords, "error": error ?? NSNull(),
        ])
    }
}
