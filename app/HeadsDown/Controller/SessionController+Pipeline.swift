import AppKit

// The autonomous pipeline:
//
//   tick (every 400 ms): locate the target window → small capture → queue a cover rebuild off the
//     main actor if its colors changed → compare with the baseline the regions came from (areas of
//     tracked scroll panes excluded) → close keep holes over changed areas → record dirty reasons →
//     maybe start work
//   cycle (one lane): capture → AX + OCR (whole window, changed bands only, or none) → merge →
//     segment → commit atomically → reconcile dirty state → classify missing inputs → render
//   classification pass (same lane): classify missing inputs for the current regions without
//     re-reading the screen (task change, classifier retry)

private struct CycleContext {
    let id: UInt64
    let session: UInt64
    let revision: Int
    let task: String
    let target: TargetWindow
    let trigger: String
    let dirtySince: Date?
    let previousBaseline: Thumbnail?
    let retainedOCR: [TextObservation]
    let retainedFresh: Bool
    let previousRegions: [ScreenRegion]
}

private enum OCRPlan {
    case full(String)
    case bands([CGRect], fraction: Double)
    case reuse

    var label: String {
        switch self {
        case .full: return "full"
        case .bands: return "bands"
        case .reuse: return "reused"
        }
    }
}

private struct OCRPass {
    var lines: [TextObservation]
    var fresh: Int
    var reused: Int
}

private struct TextRead {
    let ax: AXReadResult
    let pass: OCRPass
    let notes: [String]
    let axMs: Double
    let ocrMs: Double
}

// MARK: - Tick: window tracking, cover refresh, change detection

extension SessionController {
    func tick(session: UInt64) async {
        guard session == sessionGeneration, isActive else { return }
        if overrides.expireDue() {
            rebuildDecisions()
            render()
        }
        if let hold = exposureHold, Date() >= hold.until {
            exposureHold = nil
            render()
        }

        var lostTarget = false
        var windowChanged = false
        switch WindowLocator.locate(displayID: selectedDisplayID, ignoring: overlay.windowIDs) {
        case .failure(let skip):
            if target != nil || coverage?.skipReason != skip.message {
                retainCurrentTarget()
                invalidateAll()
                target = nil
                coverage = Coverage(displayName: displayName(selectedDisplayID), skipReason: skip.message)
                activity = skip.message
                windowChanged = true
            }
            lostTarget = true
        case .success(let found):
            if let current = target, current.sameGeometry(as: found) {
                target = found
            } else {
                let hadTarget = target != nil
                if target?.windowID != found.windowID { retainCurrentTarget() }
                invalidateAll()
                target = found
                if chrome?.windowID != found.windowID { chrome = nil }
                coverage = Coverage(
                    appName: found.appName, windowTitle: found.title, windowID: found.windowID,
                    displayName: displayName(found.displayID), bounds: found.visibleRect,
                    skippedAreas: describeSkipped(found))
                activity = hadTarget ? "Window changed — re-reading" : "Found \(found.appName) window"
                windowChanged = true
            }
        }
        // Background windows keep their covers; re-clip them against the current stacking order.
        if refreshRetained() || windowChanged { render() }
        if lostTarget { return }

        guard let current = target, Date() >= captureRetryAt else { return }
        let captureStart = Date()
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
        ingest(thumb, capturedAt: captureStart)
        maybeStartWork()
    }

    private func ingest(_ thumb: Thumbnail, capturedAt: Date) {
        var pixelsChanged = true
        var appearanceChanged = true
        if let previous = latestThumb, previous.rect == thumb.rect {
            let step = thumb.diff(against: previous)
            settled = step.changedFraction < Self.settledChangeFraction
            if motionStreak.count != thumb.cellCount { motionStreak = Array(repeating: 0, count: thumb.cellCount) }
            let changedCells = Set(step.changedCells)
            for index in motionStreak.indices {
                motionStreak[index] = changedCells.contains(index) ? motionStreak[index] + 1 : 0
            }
            pixelsChanged = !step.changedCells.isEmpty
            appearanceChanged = pixelsChanged || thumb.appearanceDiffers(from: previous)
        } else {
            settled = false
            motionStreak = Array(repeating: 0, count: thumb.cellCount)
        }
        latestThumb = thumb
        latestThumbAt = capturedAt
        // Appearance refresh is independent of OCR/classification, and runs off the main actor.
        // The current image (or the placeholder) stays up until the new one is ready.
        if (appearanceChanged || coverImage == nil), mode == .blur, let target {
            coverQueue.submit(thumb, tag: CoverTag(
                session: sessionGeneration, windowID: target.windowID, rect: thumb.rect, capturedAt: capturedAt,
                radius: BlurRenderer.radiusPoints))
        }
        let stateChanged = evaluateAgainstBaseline(thumb, observedAt: capturedAt)
        trackUnexplainedLayoutChange()
        if stateChanged { render() }
    }

    /// Compares a thumbnail with the baseline the current regions came from. Updates changed
    /// regions, the layout flag, and dirty reasons. Returns true if anything render-relevant changed.
    @discardableResult
    func evaluateAgainstBaseline(_ thumb: Thumbnail, observedAt: Date) -> Bool {
        guard let baseline else { return false }
        let diff = thumb.diff(against: baseline)
        // Tracked scroll panes are explained by their measured movement (or masked when it can't be
        // measured); only the rest of the window is judged by the raw comparison.
        var changedCells = diff.changedCells
        var changedFraction = diff.changedFraction
        let tracked = trackers.map(\.pane.viewport)
        if !tracked.isEmpty {
            let considered = Set((0..<thumb.cellCount).filter { index in
                !tracked.contains { $0.contains(thumb.cellRect(index).center) }
            })
            changedCells = changedCells.filter(considered.contains)
            changedFraction = considered.isEmpty ? 0 : Double(changedCells.count) / Double(considered.count)
        }
        let changedRects = changedCells.map(thumb.cellRect)
        let newLayout = changedFraction > Self.layoutChangeFraction
        let newChanged = changedIDs(for: changedRects)
        dirtyReasons.subtract([.layout, .localChange, .motion])
        if newLayout {
            dirtyReasons.insert(.layout)
        } else if !changedCells.isEmpty {
            // Persistent animation that doesn't touch anything left visible is already covered;
            // it only earns an occasional recheck instead of a re-read every few seconds.
            // Only Strict's keep holes reveal content that must be re-checked when it animates.
            let keepRects = strictness.coversWholeWindow
                ? regions.filter { decisions[$0.id]?.visibleIntent == true }.map(\.rect) : []
            let animating = changedCells.allSatisfy {
                $0 < motionStreak.count && motionStreak[$0] >= Self.motionStreakTicks
            }
            let touchesKeep = changedRects.contains { cell in keepRects.contains { $0.intersects(cell) } }
            dirtyReasons.insert(animating && !touchesKeep ? .motion : .localChange)
        }
        if dirtyReasons.isEmpty {
            dirtySince = nil
        } else if dirtySince == nil {
            dirtySince = observedAt
        }
        let changed = newLayout != layoutChanged || newChanged != changedRegionIDs
        layoutChanged = newLayout
        if newChanged != changedRegionIDs { changedRegionIDs = newChanged }
        return changed
    }

    private func maybeStartWork() {
        guard laneTask == nil, let task = currentTask, let current = target else { return }
        let now = Date()
        let urgent: Set<DirtyReason> = [.newTarget, .layout, .localChange, .scroll]
        if !dirtyReasons.isDisjoint(with: urgent) {
            let age = now.timeIntervalSince(dirtySince ?? now)
            let ready = dirtyReasons.contains(.newTarget)
                ? settled || age >= 1.0
                : (settled && age >= Self.debounce) || age >= Self.maxDirtyDelay
            guard ready, now.timeIntervalSince(lastCycleStart) >= Self.minCycleGap else { return }
            startCycle(target: current, task: task)
        } else if dirtyReasons.contains(.motion), now.timeIntervalSince(lastCycleStart) >= Self.motionRecheckInterval {
            startCycle(target: current, task: task)
        }
    }

    private func changedIDs(for changed: [CGRect]) -> Set<String> {
        guard !changed.isEmpty else { return [] }
        return Set(regions.filter { region in
            let inner = region.rect.insetBy(dx: 2, dy: 2)
            return changed.contains { $0.intersects(inner) }
        }.map(\.id))
    }

    private func thumbScale(_ target: TargetWindow) -> CGFloat {
        CGFloat(Thumbnail.width) / max(1, target.visibleRect.width)
    }
}

// MARK: - Cycle: read, group, commit

extension SessionController {
    private func startCycle(target: TargetWindow, task: String) {
        cycleCounter += 1
        let context = CycleContext(
            id: cycleCounter, session: sessionGeneration, revision: taskRevision, task: task, target: target,
            trigger: dirtyReasons.map(\.rawValue).sorted().joined(separator: "+"), dirtySince: dirtySince,
            previousBaseline: baseline, retainedOCR: retainedOCR,
            retainedFresh: Date().timeIntervalSince(lastFullOCRAt) < Self.maxRetainedOCRAge,
            previousRegions: regions)
        activeCycleID = context.id
        lastCycleStart = Date()
        laneTask = Task { [weak self] in
            await self?.runCycle(context)
            self?.laneFinished()
        }
        updateRunState()
    }

    private func laneFinished() {
        laneTask = nil
        updateRunState()
    }

    private func isCurrent(_ context: CycleContext) -> Bool {
        guard !Task.isCancelled, isActive, context.session == sessionGeneration, context.id == activeCycleID,
              let target, target.sameGeometry(as: context.target)
        else { return false }
        return true
    }

    private func runCycle(_ context: CycleContext) async {
        var timings = CycleTimings(cycleID: context.id, trigger: context.trigger)
        let started = Date()
        if let since = context.dirtySince { timings.queueMs = started.timeIntervalSince(since) * 1000 }
        activity = "Reading screen"

        // 1. Capture.
        let captureStart = Date()
        guard let (baseThumb, snapshot, trackImage) = await captureFrames(context) else { return }
        timings.captureMs = elapsedMs(since: captureStart)
        guard isCurrent(context) else { return }
        clearCaptureProblem()

        // 2. AX (bounded, always fresh) and OCR (scoped to what changed) in parallel.
        let plan = ocrPlan(context, newThumb: baseThumb)
        timings.ocrScope = plan.label
        if case .bands(_, let fraction) = plan { timings.ocrBandFraction = fraction }
        if case .reuse = plan { timings.ocrBandFraction = 0 }
        let referenceJob = Self.trackingReference(image: trackImage, target: context.target, capturedAt: captureStart)
        let read = await readText(context, plan: plan, snapshot: snapshot)
        timings.axMs = read.axMs
        timings.ocrMs = read.ocrMs
        timings.ocrFresh = read.pass.fresh
        timings.ocrReused = read.pass.reused
        guard isCurrent(context) else { return }

        // 3. Merge sources and group into regions.
        activity = "Grouping text into regions"
        let groupStart = Date()
        let (segmentation, stats) = await Self.group(target: context.target, ax: read.ax, ocr: read.pass.lines)
        timings.groupMs = elapsedMs(since: groupStart)
        timings.axNodes = read.ax.nodesVisited
        timings.axTexts = read.ax.texts.count
        timings.regionCount = segmentation.regions.count
        guard isCurrent(context) else { return }

        // 4. Commit atomically, then reconcile dirty state.
        let reference = await referenceJob.value
        guard isCurrent(context) else { return }
        commit(context, baseThumb: baseThumb, captureStart: captureStart, plan: plan, read: read,
               segmentation: segmentation, reference: reference)
        updateCoverage(
            target: context.target, ax: read.ax, stats: stats, segmentation: segmentation, notes: read.notes, ocr: plan)
        countMisses(previous: context.previousRegions, revision: context.revision, timings: &timings)
        scheduler.recordCacheHits(timings.cacheHits)
        rebuildDecisions()
        render()

        // 5. Hand inputs without a cached score to the scheduler and finish this read without
        //    waiting for the network. Scores arrive per request and update the overlay as they land.
        syncClassification()

        timings.totalMs = elapsedMs(since: started)
        timings.changeToOverlayMs = context.dirtySince.map { elapsedMs(since: $0) }
        lastTimings = timings
        activity = classifierProblem ?? summaryActivity()
        logCycle(context: context, timings: timings, axUsed: stats.axKept > 0)
    }

    /// Baseline thumbnail first, then the full frame, then the scroll-tracking reference. With this
    /// order a change landing between captures shows up as "changed since read" (an extra re-read)
    /// instead of being silently missed. The thumbnail and the tracking reference use the same
    /// capture path and scale as the tick thumbnails and live tracking frames, so comparisons match
    /// pixel for pixel (a downscaled Retina frame renders text edges differently).
    private func captureFrames(_ context: CycleContext) async -> (Thumbnail, ScreenSnapshot, CGImage?)? {
        let target = context.target
        let captureStart = Date()
        let scale = Geometry.backingScale(for: target.displayID)
        do {
            let (small, _) = try await capturer.capture(
                rect: target.visibleRect, displayID: target.displayID, pixelsPerPoint: thumbScale(target))
            let (full, geometry) = try await capturer.capture(
                rect: target.visibleRect, displayID: target.displayID, pixelsPerPoint: scale)
            let track = try? await capturer.capture(
                rect: target.visibleRect, displayID: target.displayID,
                pixelsPerPoint: TrackFrame.pixelsPerPoint(for: target.visibleRect))
            guard let thumb = Thumbnail(image: small, rect: target.visibleRect) else { return nil }
            let snapshot = ScreenSnapshot(cycleID: context.id, capturedAt: captureStart, geometry: geometry, image: full)
            return (thumb, snapshot, track?.0)
        } catch {
            if isCurrent(context) { handleCaptureFailure(error) }
            return nil
        }
    }

    /// The cycle's tracking-scale capture as a frame: what scroll tracking measures against.
    private static func trackingReference(
        image: CGImage?, target: TargetWindow, capturedAt: Date
    ) -> Task<TrackFrame?, Never> {
        let occluders = target.occluders.map(\.rect)
        let scale = TrackFrame.pixelsPerPoint(for: target.visibleRect)
        return Task.detached(priority: .userInitiated) {
            guard let image else { return nil }
            return TrackFrame(image: image, rect: target.visibleRect, pixelsPerPoint: scale,
                              capturedAt: capturedAt, masking: occluders)
        }
    }

    private func readText(_ context: CycleContext, plan: OCRPlan, snapshot: ScreenSnapshot) async -> TextRead {
        let axAllowed = Permissions.accessibilityGranted
        accessibilityGranted = axAllowed
        activity = switch plan {
        case .full: axAllowed ? "Reading accessibility tree + OCR" : "Running OCR (no accessibility)"
        case .bands: "Re-reading changed areas"
        case .reuse: "Re-checking layout"
        }
        let target = context.target
        let cycleID = context.id
        let retained = context.retainedOCR
        let axJob = Task.detached(priority: .userInitiated) { () -> (AXReadResult, Double) in
            let start = Date()
            let result = axAllowed
                ? AccessibilityReader.read(target: target, generation: cycleID)
                : AXReadResult(status: "Accessibility not granted")
            return (result, elapsedMs(since: start))
        }
        let ocrJob = Task.detached(priority: .userInitiated) { () -> (Result<OCRPass, Error>, Double) in
            let start = Date()
            let result = Result {
                try Self.runOCR(plan: plan, snapshot: snapshot, retained: retained,
                                windowID: target.windowID, cycleID: cycleID)
            }
            return (result, elapsedMs(since: start))
        }
        let (ax, axMs) = await axJob.value
        let (ocrResult, ocrMs) = await ocrJob.value
        switch ocrResult {
        case .success(let pass):
            return TextRead(ax: ax, pass: pass, notes: [], axMs: axMs, ocrMs: ocrMs)
        case .failure(let error):
            return TextRead(
                ax: ax, pass: OCRPass(lines: [], fresh: 0, reused: 0),
                notes: ["OCR failed: \(error.localizedDescription)"], axMs: axMs, ocrMs: ocrMs)
        }
    }

    private nonisolated static func runOCR(
        plan: OCRPlan, snapshot: ScreenSnapshot, retained: [TextObservation], windowID: CGWindowID, cycleID: UInt64
    ) throws -> OCRPass {
        switch plan {
        case .full:
            let lines = try OCRRecognizer.recognize(
                image: snapshot.image, geometry: snapshot.geometry, windowID: windowID, generation: cycleID)
            return OCRPass(lines: lines, fresh: lines.count, reused: 0)
        case .bands(let bands, _):
            let fresh = try OCRRecognizer.recognize(
                bands: bands, image: snapshot.image, geometry: snapshot.geometry, windowID: windowID,
                generation: cycleID)
            let kept = retained.filter { line in !bands.contains { $0.intersects(line.rect) } }
            return OCRPass(lines: kept + fresh, fresh: fresh.count, reused: kept.count)
        case .reuse:
            return OCRPass(lines: retained, fresh: 0, reused: retained.count)
        }
    }

    private static func group(
        target: TargetWindow, ax: AXReadResult, ocr: [TextObservation]
    ) async -> (SegmentationOutput, MergeStats) {
        let occluderRects = target.occluders.map(\.rect)
        return await Task.detached(priority: .userInitiated) {
            let (merged, stats) = ObservationMerger.merge(
                accessibility: ax.texts, ocr: ocr, visibleRect: target.visibleRect, occluders: occluderRects)
            let output = Segmenter.segment(SegmentationInput(
                observations: merged, containers: ax.containers, visibleRect: target.visibleRect,
                occluders: occluderRects, appName: target.appName, windowTitle: target.title,
                windowID: target.windowID))
            return (output, stats)
        }.value
    }

    /// Commits regions, baseline, retained OCR, chrome, controls, and scroll tracking state together,
    /// so the next render swaps tracked geometry for the new read without an empty frame.
    private func commit(
        _ context: CycleContext, baseThumb: Thumbnail, captureStart: Date, plan: OCRPlan, read: TextRead,
        segmentation: SegmentationOutput, reference: TrackFrame?
    ) {
        let target = context.target
        let fresh = inheritEdgeIdentity(segmentation.regions, target: target, capturedAt: captureStart)
        // Exposure holds and tracker rebasing look at the outgoing regions and their decisions.
        reconcileTrackers(reference: reference, captureStartedAt: captureStart)
        regions = fresh
        baseline = baseThumb
        retainedOCR = read.pass.lines
        if case .full = plan { lastFullOCRAt = captureStart }
        if read.ax.windowMatched {
            chrome = ContentEnvelope.chrome(for: target, layout: read.ax.layoutFrames)
        } else if chrome?.windowID != target.windowID {
            chrome = ContentEnvelope.fallback(for: target, reason: read.ax.status)
        }
        controlRects = read.ax.windowMatched ? read.ax.controls : []
        scrollPanes = read.ax.windowMatched
            ? read.ax.scrollAreas.map { ScrollPane(viewport: $0.rect, role: $0.role, fromAX: true) } : []
        // The frontmost window's own read replaces any cover kept from when it was in the background.
        retainedWindows[target.windowID] = nil
        reconcileAfterCommit(captureStartedAt: captureStart)
        if let selected = selectedRegionID, !regions.contains(where: { $0.id == selected }) { selectedRegionID = nil }
    }

    /// Consumes dirty state the committed frame already incorporates; keeps anything newer.
    private func reconcileAfterCommit(captureStartedAt: Date) {
        dirtyReasons.subtract([.newTarget, .layout, .localChange, .motion])
        if !trackers.isEmpty {
            // A pane kept moving after this capture: its geometry is tracked, and another read follows.
            dirtyReasons.insert(.scroll)
        } else if lastScrollAt < captureStartedAt {
            dirtyReasons.remove(.scroll)
        }
        let lastActivity = trackers.map(\.lastActivityAt).max().map { max($0, lastScrollAt) } ?? lastScrollAt
        dirtySince = dirtyReasons.isEmpty ? nil : lastActivity
        layoutChanged = false
        if !changedRegionIDs.isEmpty { changedRegionIDs = [] }
        if let latest = latestThumb, latestThumbAt > captureStartedAt {
            evaluateAgainstBaseline(latest, observedAt: latestThumbAt)
        }
    }

    private func ocrPlan(_ context: CycleContext, newThumb: Thumbnail) -> OCRPlan {
        guard let previous = context.previousBaseline, previous.rect == newThumb.rect else {
            return .full("no previous frame")
        }
        guard !context.retainedOCR.isEmpty, context.retainedFresh else { return .full("retained OCR missing or old") }
        let diff = newThumb.diff(against: previous)
        if diff.changedCells.isEmpty { return .reuse }
        if diff.changedFraction > Self.layoutChangeFraction { return .full("layout change") }
        let bands = Self.ocrBands(changed: diff.changedRects, visible: newThumb.rect, retained: context.retainedOCR)
        let height = bands.reduce(CGFloat(0)) { $0 + $1.height }
        if height > Self.fullOCRBandFraction * newThumb.rect.height { return .full("changes too spread out") }
        return .bands(bands, fraction: Double(height / newThumb.rect.height))
    }

    /// Full-width horizontal bands around changed cells, grown so no retained OCR line is cut.
    static func ocrBands(changed: [CGRect], visible: CGRect, retained: [TextObservation]) -> [CGRect] {
        let margin: CGFloat = 8
        var ranges = changed.map { (low: $0.minY - margin, high: $0.maxY + margin) }
        for _ in 0..<6 {
            ranges = mergeRanges(ranges)
            var grew = false
            ranges = ranges.map { range in
                var (low, high) = range
                for line in retained where line.rect.minY < high && line.rect.maxY > low {
                    if line.rect.minY - 2 < low { low = line.rect.minY - 2; grew = true }
                    if line.rect.maxY + 2 > high { high = line.rect.maxY + 2; grew = true }
                }
                return (low, high)
            }
            if !grew { break }
        }
        return mergeRanges(ranges).compactMap { range in
            let top = max(range.low, visible.minY), bottom = min(range.high, visible.maxY)
            return bottom - top >= 4 ? CGRect(x: visible.minX, y: top, width: visible.width, height: bottom - top) : nil
        }
    }

    private static func mergeRanges(_ ranges: [(low: CGFloat, high: CGFloat)]) -> [(low: CGFloat, high: CGFloat)] {
        var merged: [(low: CGFloat, high: CGFloat)] = []
        for range in ranges.sorted(by: { $0.low < $1.low }) {
            if let last = merged.last, range.low <= last.high {
                merged[merged.count - 1].high = max(last.high, range.high)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    func handleCaptureFailure(_ error: Error) {
        invalidateAll()
        captureRetryAt = Date().addingTimeInterval(captureBackoff)
        captureBackoff = min(captureBackoff * 2, Self.maxCaptureBackoff)
        let permissionHint = Permissions.screenRecordingGranted ? "" : " (Screen Recording may be off)"
        captureProblem = "Not covering: screen capture unavailable\(permissionHint): \(error.localizedDescription)"
        activity = captureProblem ?? ""
        updateRunState()
        Task { await capturer.invalidate() }
        log(["event": "capture_error", "error": String(describing: type(of: error))])
    }

    func clearCaptureProblem() {
        guard captureProblem != nil else { return }
        captureProblem = nil
        captureBackoff = 1
        updateRunState()
    }
}

// MARK: - Classification

extension SessionController {
    func cacheKey(_ region: ScreenRegion, revision: Int) -> String {
        ScoreCache.key(
            revision: revision, provider: classifier.providerID, question: classifier.questionVersion,
            input: region.classifierFingerprint)
    }

    /// Tells the scheduler which inputs the current front-window regions still need. Cached inputs
    /// are skipped (their scores already apply); unsent inputs no longer on screen are dropped.
    /// Background (retained) windows never cause new classification.
    func syncClassification() {
        guard let task = currentTask, isActive else { return }
        var items: [(key: String, input: ClassifierInput)] = []
        var seen = Set<String>()
        for region in regions {
            let key = cacheKey(region, revision: taskRevision)
            guard scoreCache.peek(key) == nil, seen.insert(key).inserted else { continue }
            items.append((key, ClassifierInput(app: region.appName, title: region.windowTitle, text: region.text)))
        }
        scheduler.update(task: task, revision: taskRevision, items: items)
    }

    /// Scores arriving from the scheduler, one request at a time. They're cached by semantic key
    /// immediately; whatever regions currently show that content pick them up, and old rectangles
    /// are never revived (rendering uses only current regions and geometry).
    func scoresArrived(_ scores: [(key: String, score: Double)]) {
        for entry in scores { scoreCache.set(entry.key, entry.score) }
        guard isActive else { return }
        rebuildDecisions()
        render()
        if classifierProblem == nil, laneTask == nil { activity = summaryActivity() }
    }

    func classifierProblemChanged(_ problem: String?) {
        classifierProblem = problem.map { "\($0) — unscored content: \(strictness.coversWholeWindow ? "covered" : "left visible")" }
        classifierStatus = problem ?? "Ready"
        updateRunState()
        if let classifierProblem { activity = classifierProblem }
    }

    /// Seconds until paid classification may be dispatched (0 = now), or nil to wait for the next
    /// read. Classification waits until scrolling over the target stops and a read taken after the
    /// last scroll has replaced the pending inputs, so intermediate scroll positions aren't sent.
    func classificationGateDelay() -> TimeInterval? {
        guard isActive else { return nil }
        if dirtyReasons.contains(.scroll) { return nil }
        let quiet = Date().timeIntervalSince(lastScrollAt)
        return quiet >= Self.scrollQuiet ? 0 : Self.scrollQuiet - quiet
    }

    /// Coarse miss causes for diagnostics: a region at the same place with different input
    /// ("changed") versus no region there before ("new").
    private func countMisses(previous: [ScreenRegion], revision: Int, timings: inout CycleTimings) {
        // Touch cached entries so the LRU keeps what's on screen.
        timings.cacheHits = regions.filter { scoreCache.get(cacheKey($0, revision: revision)) != nil }.count
        for region in regions where scoreCache.peek(cacheKey(region, revision: revision)) == nil {
            if previous.contains(where: { $0.rect.overlapFraction(of: region.rect) >= 0.8 }) {
                timings.missesChanged += 1
            } else {
                timings.missesNew += 1
            }
        }
    }
}

// MARK: - Policy and rendering

extension SessionController {
    func rebuildDecisions() {
        var result: [String: RegionDecision] = [:]
        let policyVersion = Policy.version(strictness)
        for region in regions {
            let score = scoreCache.peek(cacheKey(region, revision: taskRevision))
            let expiry = overrides.expiry(revision: taskRevision, fingerprint: region.fingerprint)
            let (verdict, visibleIntent, note) = Policy.decide(
                score: score, strictness: strictness, revealed: expiry != nil, revealExpiry: expiry)
            result[region.id] = RegionDecision(
                regionID: region.id, fingerprint: region.fingerprint, taskRevision: taskRevision,
                providerID: classifier.providerID, questionVersion: classifier.questionVersion,
                policyVersion: policyVersion, pDistracting: score, verdict: verdict, visibleIntent: visibleIntent,
                overridden: expiry != nil, policyNote: note, decidedAt: Date())
        }
        decisions = result
    }

    /// Builds the whole overlay scene from current state and swaps it in at once (see `frontLayer`
    /// for what each hiding level covers, including while a pane scrolls).
    func render() {
        guard isActive else {
            overlay.clear()
            if !visibleRegionIDs.isEmpty { visibleRegionIDs = [] }
            if renderedCover != "None" { renderedCover = "None" }
            return
        }
        var scene = OverlayScene()
        if mode != .observe {
            // Back to front. A window that just became frontmost keeps its background cover until re-read.
            let background = retainedWindows.values
                .filter { $0.windowID != target?.windowID || regions.isEmpty }
                .sorted { $0.stackIndex > $1.stackIndex }
            scene.layers = background.compactMap(retainedLayer)
        }
        var coverLabel = mode == .observe ? "None (Observe mode)" : "No front window"
        var visible = Set<String>()
        if let target {
            let front = frontLayer(target)
            visible = front.visible
            scene.boxes = front.boxes
            if let layer = front.layer { scene.layers.append(layer) }
            coverLabel = front.label
        }
        if !scene.layers.isEmpty, mode != .observe, !retainedWindows.isEmpty {
            coverLabel += " · \(retainedWindows.count) background window(s) kept covered"
        }
        overlay.update(displayID: selectedDisplayID, scene: scene)
        if visible != visibleRegionIDs { visibleRegionIDs = visible }
        if coverLabel != renderedCover { renderedCover = coverLabel }
    }

    /// The frontmost window's layer.
    ///
    /// - Relaxed/Balanced: only distracting regions are covered. Their covers survive local content
    ///   changes and follow a scrolled pane's measured movement. Where movement can't be measured
    ///   (or content was just exposed), a pane that had covered content is masked until re-read.
    /// - Strict: the whole window is covered except keep holes, which close while their pixels
    ///   differ from what was read or on an unexplained layout change, and shrink by the tracking
    ///   margin while they follow a scrolled pane (reveals survive local changes).
    /// In every level, window chrome and higher windows stay visible; interactive controls stay
    /// visible where their position is known.
    private func frontLayer(
        _ target: TargetWindow
    ) -> (layer: OverlayScene.Layer?, visible: Set<String>, boxes: [OverlayScene.Box], label: String) {
        let now = Date()
        let wholeWindow = strictness.coversWholeWindow
        var holes: [CGRect] = []
        var coveredRegions: [CGRect] = []
        var visible = Set<String>()
        var boxes: [OverlayScene.Box] = []
        var moved = 0, gone = 0
        for region in regions {
            let decision = decisions[region.id]
            let placement = placement(of: region.rect, now: now)
            // Raw pixel changes inside a tracked pane come from scrolling, not from this region.
            let changed = changedRegionIDs.contains(region.id) && !trackers.contains { $0.owns(region.rect) }
            let revealed = decision?.overridden == true
            let covered: Bool
            switch placement {
            case .fresh(let rect):
                if mode == .observe {
                    covered = false
                } else if wholeWindow {
                    covered = !(decision?.visibleIntent == true && (!changed || revealed))
                    if !covered { holes.append(rect) }
                } else {
                    covered = decision?.visibleIntent == false || heldAfterScroll(region, decision: decision)
                    if covered { coveredRegions.append(rect) }
                }
                if showBoxes, !changed {
                    boxes.append(OverlayScene.Box(
                        rect: rect, label: badgeLabel(region, decision), color: verdictColor(decision),
                        dashed: region.geometryUncertain))
                }
            case .moved(let rect, let margin, let index):
                moved += 1
                let tracker = trackers[index]
                if mode == .observe {
                    covered = false
                } else if wholeWindow {
                    // Conservative keep hole: shrunk by the margin, closed over unverified cells and
                    // where moving content passes under fixed parts of the pane.
                    let hole = rect.insetBy(dx: margin, dy: margin)
                    let blocked = tracker.unreliableRects.contains { $0.intersects(rect) }
                        || (!tracker.isFixed(region.rect) && tracker.fixedRects.contains { $0.intersects(rect) })
                    covered = !(decision?.visibleIntent == true && !blocked && hole.width >= 4 && hole.height >= 4)
                    if !covered { holes.append(hole) }
                } else {
                    covered = decision?.visibleIntent == false
                    if covered {
                        coveredRegions.append(rect.insetBy(dx: -margin, dy: -margin).intersection(tracker.pane.viewport))
                    }
                }
                if showBoxes {
                    boxes.append(OverlayScene.Box(
                        rect: rect, label: badgeLabel(region, decision), color: verdictColor(decision), dashed: true))
                }
            case .unknown:
                // Drawn by the transition mask below if anything around it was covered.
                covered = mode != .observe && (wholeWindow || decision?.visibleIntent == false)
            case .gone:
                gone += 1
                covered = true
            }
            if !covered { visible.insert(region.id) }
        }
        guard mode != .observe else { return (nil, visible, boxes, "None (Observe mode)") }
        let currentChrome = chrome.flatMap { $0.windowID == target.windowID ? $0 : nil }
            ?? ContentEnvelope.fallback(for: target, reason: "layout not read yet")
        let masks = wholeWindow ? [] : transitionMasks(target, now: now)
        var style = coverStyle(image: coverImage, rect: target.visibleRect, fill: coverFill)
        var shifted = 0
        if case .image(let image, let rect, _, let fill) = style.cover {
            let shifts = coverShifts()
            shifted = shifts.count
            style.cover = .image(image, rect: rect, shifts: shifts, fill: fill)
        }
        let layer = OverlayScene.Layer(
            coverAreas: wholeWindow ? [target.visibleRect] : coveredRegions + masks,
            cover: style.cover,
            visibleRects: [ContentEnvelope.chromeBand(currentChrome, target: target)]
                + target.occluders.map(\.rect) + currentControls(target, now: now) + holes)
        var scope = wholeWindow ? "whole window" : "\(coveredRegions.count) region(s)"
        if !masks.isEmpty { scope += " + \(masks.count) scroll/transition mask(s)" }
        if moved > 0 || gone > 0 { scope += " · \(moved) following scroll, \(gone) scrolled out" }
        if shifted > 0 { scope += " · cover image reused, shifted with \(shifted) pane(s)" }
        return (layer, visible, boxes, "\(style.label), \(scope)")
    }

    /// Balanced/Relaxed fallback coverage while geometry is uncertain, only where something was
    /// covered (an all-visible pane is never masked just because it scrolled):
    /// an unmeasurable pane → its viewport; a measured pane → newly exposed strips and unverified cells;
    /// an unexplained layout change outside tracked panes → the content area.
    private func transitionMasks(_ target: TargetWindow, now: Date) -> [CGRect] {
        var masks: [CGRect] = []
        for tracker in trackers where paneHasCover(tracker) {
            if case .lost = tracker.effectiveState(now: now) {
                masks.append(tracker.pane.viewport)
            } else {
                masks += tracker.exposedRects + tracker.unreliableRects
            }
        }
        if layoutChanged, regions.contains(where: { region in
            decisions[region.id]?.visibleIntent == false && !trackers.contains { $0.owns(region.rect) }
        }) {
            masks.append(contentArea(target))
        }
        return masks
    }

    /// Control exemptions at their current positions. Controls inside a scrolled pane move with it;
    /// where their position is uncertain they're not exempted (chrome stays visible regardless).
    private func currentControls(_ target: TargetWindow, now: Date) -> [CGRect] {
        controlRects.compactMap { control in
            switch placement(of: control, now: now) {
            case .fresh(let rect):
                return rect
            case .moved(let rect, let margin, let index):
                guard !trackers[index].unreliableRects.contains(where: { $0.intersects(rect) }) else { return nil }
                let inset = min(margin, 3)
                let shrunk = rect.insetBy(dx: inset, dy: inset)
                return shrunk.width > 2 && shrunk.height > 2 ? shrunk : nil
            case .unknown, .gone:
                return nil
            }
        }
    }

    /// Cover for a background window, from what was read while it was frontmost and the current policy.
    private func retainedLayer(_ window: RetainedWindow) -> OverlayScene.Layer? {
        let wholeWindow = strictness.coversWholeWindow
        var areas: [CGRect] = wholeWindow ? [window.visibleRect] : []
        var holes: [CGRect] = []
        for region in window.regions {
            let visible = policyAllowsVisible(region)
            if wholeWindow, visible { holes.append(region.rect) }
            if !wholeWindow, !visible { areas.append(region.rect) }
        }
        guard !areas.isEmpty else { return nil }
        if let chrome = window.chrome { holes.append(ContentEnvelope.chromeBand(chrome, visible: window.visibleRect)) }
        return OverlayScene.Layer(
            coverAreas: areas, cover: coverStyle(image: window.coverImage, rect: window.visibleRect).cover,
            visibleRects: holes + window.controls + window.occluders)
    }

    private func coverStyle(
        image: CGImage?, rect: CGRect, fill: CGColor? = nil
    ) -> (cover: OverlayScene.Cover, label: String) {
        if mode == .dim { return (.dim, "Dark mask") }
        if let image { return (.image(image, rect: rect, shifts: [], fill: fill), "Blurred live thumbnail") }
        return (.placeholder, "Neutral placeholder")
    }

    private func policyAllowsVisible(_ region: ScreenRegion) -> Bool {
        let score = scoreCache.peek(cacheKey(region, revision: taskRevision))
        let expiry = overrides.expiry(revision: taskRevision, fingerprint: region.fingerprint)
        return Policy.decide(score: score, strictness: strictness, revealed: expiry != nil, revealExpiry: expiry).1
    }

    /// Remembers the frontmost window's cover before focus moves elsewhere. Skipped while its
    /// geometry is stale (mid-scroll or layout change).
    func retainCurrentTarget() {
        guard let target, !regions.isEmpty, !layoutChanged, trackers.isEmpty else { return }
        retainedWindows[target.windowID] = RetainedWindow(
            windowID: target.windowID, bounds: target.bounds, visibleRect: target.visibleRect,
            regions: regions.filter { !changedRegionIDs.contains($0.id) },
            chrome: chrome.flatMap { $0.windowID == target.windowID ? $0 : nil },
            controls: controlRects, coverImage: coverImage, retainedAt: Date())
        while retainedWindows.count > Self.maxRetainedWindows,
              let oldest = retainedWindows.values.min(by: { $0.retainedAt < $1.retainedAt }) {
            retainedWindows[oldest.windowID] = nil
        }
    }

    /// Drops background covers whose window moved, closed, minimized, or left this Space, and
    /// re-clips the rest against windows now above them. Returns true if anything changed.
    private func refreshRetained() -> Bool {
        guard !retainedWindows.isEmpty else { return false }
        let stack = WindowLocator.stack(displayID: selectedDisplayID, ignoring: overlay.windowIDs)
        var changed = false
        for (id, var window) in retainedWindows {
            guard let index = stack.firstIndex(where: { $0.id == id }), stack[index].bounds == window.bounds else {
                retainedWindows[id] = nil
                changed = true
                continue
            }
            let occluders = stack[..<index]
                .filter { $0.layer < WindowLocator.ignoredOverlayLayer }
                .map { $0.bounds.intersection(window.visibleRect) }
                .filter { !$0.isNull && $0.area > 0 }
            if occluders != window.occluders || index != window.stackIndex {
                window.occluders = occluders
                window.stackIndex = index
                retainedWindows[id] = window
                changed = true
            }
        }
        return changed
    }

    private func badgeLabel(_ region: ScreenRegion, _ decision: RegionDecision?) -> String {
        var label = "#\(region.number)"
        label += decision?.pDistracting.map { String(format: " %.2f", $0) } ?? " ?"
        if decision?.overridden == true { label += " revealed" }
        return label
    }

    private func verdictColor(_ decision: RegionDecision?) -> NSColor {
        guard let decision else { return .systemGray }
        if decision.overridden { return .systemBlue }
        switch decision.verdict {
        case .keep: return .systemGreen
        case .cover: return .systemRed
        case .unknown: return .systemGray
        }
    }

    func summaryActivity() -> String {
        let unknown = regions.filter { decisions[$0.id]?.verdict == .unknown }.count
        let hidden = regions.count - visibleRegionIDs.count
        var text: String
        if mode == .observe {
            text = "Observing \(regions.count) region\(regions.count == 1 ? "" : "s") (nothing hidden)"
        } else if strictness.coversWholeWindow {
            text = "Hiding all but \(visibleRegionIDs.count) related region\(visibleRegionIDs.count == 1 ? "" : "s")"
        } else {
            text = "Hiding \(hidden) distracting region\(hidden == 1 ? "" : "s") of \(regions.count)"
        }
        if unknown > 0 { text += " · \(unknown) unscored" }
        return text
    }
}

// MARK: - Coverage and diagnostics

extension SessionController {
    private func describeSkipped(_ target: TargetWindow) -> [String] {
        target.occluders.map { "Not covered: under \($0.owner) (layer \($0.layer)) — \($0.rect.shortDescription)" }
            + target.ignoredOverlays.map {
                "Ignored overlay from \($0.owner) (layer \($0.layer)), assumed transparent — \($0.rect.shortDescription)"
            }
    }

    private func updateCoverage(
        target: TargetWindow, ax: AXReadResult, stats: MergeStats, segmentation: SegmentationOutput,
        notes: [String], ocr: OCRPlan
    ) {
        var info = Coverage(
            appName: target.appName, windowTitle: target.title, windowID: target.windowID,
            displayName: displayName(target.displayID), bounds: target.visibleRect)
        let source = stats.axKept > 0 ? "Accessibility + OCR" : "OCR only"
        info.readMode = switch ocr {
        case .full(let reason): "\(source) · whole-window OCR (\(reason))"
        case .bands(let bands, let fraction):
            "\(source) · OCR of \(bands.count) changed band(s), \(Int(fraction * 100))% of the window"
        case .reuse: "\(source) · OCR reused (no pixel change)"
        }
        info.axStatus = "\(ax.status) · \(ax.nodesVisited) nodes · \(ax.texts.count) texts "
            + "(\(stats.axKept) confirmed visible) · \(ax.containers.count) containers"
        info.chromeNote = chrome?.note ?? "—"
        info.skippedAreas = describeSkipped(target)
        var allNotes = notes
        allNotes.append("OCR lines: \(stats.ocrInput) (\(stats.ocrDuplicates) duplicated AX text, \(stats.ocrKept) kept)")
        if stats.axUnconfirmed > 0 {
            allNotes.append("\(stats.axUnconfirmed) AX texts had no visible OCR text under them — skipped as possibly hidden")
        }
        if segmentation.containerGroups == 0 {
            allNotes.append("No AX containers used: keep holes are text blocks only; nearby images stay covered")
        } else {
            allNotes.append("\(segmentation.containerGroups) regions use AX container bounds")
        }
        if segmentation.droppedTiny > 0 { allNotes.append("\(segmentation.droppedTiny) tiny text blocks stay covered") }
        if segmentation.droppedOverCap > 0 {
            allNotes.append("\(segmentation.droppedOverCap) blocks over the \(Segmenter.maxRegions)-region cap stay covered")
        }
        info.notes = allNotes
        coverage = info
    }

    private func logCycle(context: CycleContext, timings: CycleTimings, axUsed: Bool) {
        guard diagnosticsEnabled else { return }
        let regionRecords: [[String: Any]] = regions.map { region in
            let decision = decisions[region.id]
            return [
                "n": region.number,
                "src": region.sourceLabel,
                "chars": region.text.count,
                "p": decision?.pDistracting ?? NSNull(),
                "verdict": decision?.verdict.rawValue ?? "unknown",
                "visible": visibleRegionIDs.contains(region.id),
                "changed": changedRegionIDs.contains(region.id),
            ]
        }
        let timingRecord: [String: Any] = [
            "queue": timings.queueMs ?? NSNull(), "capture": timings.captureMs, "ax": timings.axMs,
            "ocr": timings.ocrMs, "group": timings.groupMs,
            "cycle": timings.totalMs, "change_to_overlay": timings.changeToOverlayMs ?? NSNull(),
        ]
        log([
            "event": "cycle", "cycle": context.id, "provider": classifier.providerID, "trigger": context.trigger, "task_rev": context.revision,
            "mode": mode.rawValue, "policy": Policy.version(strictness), "controls": controlRects.count, "read_mode": axUsed ? "ax+ocr" : "ocr",
            "ocr_scope": timings.ocrScope, "ocr_band_fraction": timings.ocrBandFraction,
            "ocr_fresh": timings.ocrFresh, "ocr_reused": timings.ocrReused,
            "regions": timings.regionCount, "cache_hits": timings.cacheHits,
            "misses_changed": timings.missesChanged, "misses_new": timings.missesNew,
            "pending": usage.pending, "in_flight": usage.inFlight, "session_requests": usage.httpRequests,
            "session_tokens": usage.inputTokens, "visible_regions": visibleRegionIDs.count,
            "cover": renderedCover, "pending_dirty": dirtyReasons.map(\.rawValue).sorted(),
            "ax_nodes": timings.axNodes, "ax_texts": timings.axTexts, "ms": timingRecord,
            "decisions": regionRecords,
        ])
    }
}
