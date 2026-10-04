import AppKit

// The scroll/geometry lane, independent of reading and classification:
//
//   wheel over the target (or a large unexplained thumbnail change) → find the pane →
//   measure its movement from small captures (~15 Hz while moving) → move covers/holes/controls →
//   mask the pane, newly exposed strips, or unreliable cells when movement can't be verified
//
//   after scrolling settles: the normal cycle re-reads the window; its commit replaces the tracked
//   geometry in the same main-actor turn (no empty frame) and reuses cached scores.
//
// Nothing here changes region text or fingerprints, so moving a cover never creates a new
// classifier input. The only identity rule is in `inheritEdgeIdentity`: a fragment of content cut by
// the pane edge keeps the identity of the whole region it came from.

/// Local counters for the Inspector; never content.
struct TrackStats {
    var frames = 0
    var dropped = 0
    var lastEstimateMs: Double = 0
    var lastCaptureMs: Double = 0
    var intervalMs: Double = 0
    var lastFrameAt = Date.distantPast
    /// Lost panes that measuring against the read frame brought back.
    var recoveries = 0

    mutating func recordFrame(at time: Date) {
        frames += 1
        if lastFrameAt != .distantPast {
            let gap = time.timeIntervalSince(lastFrameAt) * 1000
            if gap < 1000 { intervalMs = intervalMs == 0 ? gap : intervalMs * 0.8 + gap * 0.2 }
        }
        lastFrameAt = time
    }
}

/// One tracking frame and what was measured from it.
private struct PaneMeasurement {
    let frame: TrackFrame
    let estimate: MotionEstimator.Estimate
    /// Measured against the regions' own read frame rather than the previous tracking frame.
    let fromReference: Bool
    let ms: Double
}

/// Where a region (or control) is drawn right now.
enum Placement {
    /// Geometry from the last read is current.
    case fresh(CGRect)
    /// Moved with its pane; `margin` is the conservative slack in points.
    case moved(CGRect, margin: CGFloat, tracker: Int)
    /// Its pane moved in a way that couldn't be measured.
    case unknown
    /// Scrolled out of its pane's viewport.
    case gone
}

// MARK: - Panes and scroll lifecycle

extension SessionController {
    func contentArea(_ target: TargetWindow) -> CGRect {
        let currentChrome = chrome.flatMap { $0.windowID == target.windowID ? $0 : nil }
            ?? ContentEnvelope.fallback(for: target, reason: "layout not read yet")
        return ContentEnvelope.contentArea(currentChrome, visible: target.visibleRect)
    }

    /// The innermost AX scroll area under the pointer, else the window's content area.
    func pane(at point: CGPoint, target: TargetWindow) -> ScrollPane {
        let content = contentArea(target)
        let candidates = scrollPanes.compactMap { pane -> ScrollPane? in
            let viewport = pane.viewport.intersection(content).integral.intersection(target.visibleRect)
            guard !viewport.isNull, viewport.contains(point),
                  viewport.width >= AccessibilityReader.minScrollAreaSize.width,
                  viewport.height >= AccessibilityReader.minScrollAreaSize.height
            else { return nil }
            return ScrollPane(viewport: viewport, role: pane.role, fromAX: true)
        }
        return candidates.min { $0.viewport.area < $1.viewport.area }
            ?? ScrollPane(viewport: content.integral.intersection(target.visibleRect), role: "content area",
                          fromAX: false)
    }

    func scrollStarted(in pane: ScrollPane, now: Date) {
        guard let target, pane.viewport.area > 0 else { return }
        if let index = trackers.firstIndex(where: { $0.pane.sameArea(as: pane) }) {
            trackers[index].lastWheelAt = now
        } else if !regions.isEmpty || !controlRects.isEmpty {
            var tracker = makeTracker(pane, target: target, motionStartedAt: now, now: now)
            let overlapping = trackers.indices.filter { trackers[$0].pane.viewport.intersects(pane.viewport) }
            if !overlapping.isEmpty {
                // Nested panes scrolled in one burst: movement can't be attributed to either.
                for index in overlapping {
                    trackers[index].markLost("nested panes scrolled together")
                    trackers[index].lastWheelAt = now
                }
                tracker.markLost("nested panes scrolled together")
                log(["event": "scroll_fallback", "reason": "nested_panes"])
            }
            trackers.append(tracker)
            render()
        }
        ensureTrackingLoop()
    }

    private func makeTracker(
        _ pane: ScrollPane, target: TargetWindow, motionStartedAt: Date?, now: Date
    ) -> PaneTracker {
        trackerCounter += 1
        let scale = TrackFrame.pixelsPerPoint(for: target.visibleRect)
        let reference = trackingReference.flatMap { frame -> TrackFrame? in
            guard frame.rect == target.visibleRect else { return nil }
            return frame.cropped(to: pane.viewport)?.masked(target.occluders.map(\.rect))
        }
        return PaneTracker(id: trackerCounter, pane: pane, pixelsPerPoint: scale, reference: reference,
                           motionStartedAt: motionStartedAt, now: now)
    }

    /// Scrolling that arrived without wheel events (keyboard, scroll bars, withheld events): a large
    /// thumbnail change starts tracking the content area. If it was really navigation, measuring
    /// fails and the fallback mask applies, as it would have anyway.
    func trackUnexplainedLayoutChange() {
        guard layoutChanged, trackers.isEmpty, trackingReference != nil, !regions.isEmpty, let target,
              Date().timeIntervalSince(lastScrollAt) > 1
        else { return }
        let content = contentArea(target)
        let pane = scrollPanes.filter { $0.viewport.intersection(content).area >= 0.5 * content.area }
            .max { $0.viewport.area < $1.viewport.area }
            .map { ScrollPane(viewport: $0.viewport.intersection(content).integral, role: $0.role, fromAX: true) }
            ?? ScrollPane(viewport: content.integral.intersection(target.visibleRect), role: "content area",
                          fromAX: false)
        let now = Date()
        trackers.append(makeTracker(pane, target: target, motionStartedAt: nil, now: now))
        // The pane's change is now explained by tracking; `.scroll` makes sure it is re-read after.
        dirtyReasons.insert(.scroll)
        if dirtySince == nil { dirtySince = now }
        if let latest = latestThumb { evaluateAgainstBaseline(latest, observedAt: latestThumbAt) }
        ensureTrackingLoop()
    }

    func stopTracking() {
        trackTask?.cancel()
        trackTask = nil
        trackLoopToken += 1
        if !trackers.isEmpty { logTracking(outcome: "dropped") }
        trackers = []
        if scrollStatus != "Not scrolling" { scrollStatus = "Not scrolling" }
    }

    // MARK: - Measurement loop

    /// One bounded loop for all scrolled panes: capture → measure off the main actor → apply.
    /// Frames are processed one at a time, so nothing queues up behind a slow capture.
    func ensureTrackingLoop() {
        guard trackTask == nil, isActive else { return }
        trackLoopToken += 1
        let token = trackLoopToken
        let session = sessionGeneration
        trackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.sessionGeneration == session, self.trackLoopToken == token else { return }
                let started = Date()
                guard await self.trackStep(session: session) else { break }
                let wait = Self.trackInterval - Date().timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            }
            guard let self, self.trackLoopToken == token else { return }
            self.trackTask = nil
        }
    }

    /// Measures every pane that's moving. Returns false when nothing needs frames any more.
    private func trackStep(session: UInt64) async -> Bool {
        guard isActive, session == sessionGeneration, let target else { return false }
        let wanted = trackers.filter { $0.wantsFrames(now: Date(), quiet: Self.trackQuiet) }.map(\.id)
        guard !wanted.isEmpty else {
            updateScrollStatus()
            return false
        }
        for id in wanted {
            guard let tracker = trackers.first(where: { $0.id == id }) else { continue }
            await measure(tracker, target: target, session: session)
        }
        updateScrollStatus()
        return true
    }

    private func measure(_ tracker: PaneTracker, target: TargetWindow, session: UInt64) async {
        let viewport = tracker.pane.viewport
        let scale = tracker.pixelsPerPoint
        let epoch = tracker.epoch
        let masks = target.occluders.map(\.rect).filter { $0.intersects(viewport) }
        let previous = tracker.isLost ? nil : tracker.previous
        let reference = tracker.reference
        let referenceFirst = tracker.prefersReference
        let captureStart = Date()
        let image: CGImage
        let cropRect: CGRect
        do {
            let (captured, geometry) = try await capturer.capture(
                rect: viewport, displayID: target.displayID, pixelsPerPoint: scale)
            image = captured
            cropRect = geometry.cropRect
        } catch {
            if let index = currentTrackerIndex(id: tracker.id, epoch: epoch, target: target, session: session) {
                trackers[index].markLost("capture failed")
                render()
            }
            return
        }
        trackStats.lastCaptureMs = elapsedMs(since: captureStart)
        let measured = await Task.detached(priority: .userInitiated) { () -> PaneMeasurement? in
            let start = Date()
            let size = (reference ?? previous).map { (width: $0.width, height: $0.height) }
            guard let frame = TrackFrame(image: image, rect: cropRect, pixelsPerPoint: scale, capturedAt: captureStart,
                                         masking: masks, pixelSize: size)
            else { return nil }
            // Previous frame for continuity, the read frame to confirm or recover. One failed step
            // doesn't lose the pane while the content still overlaps what was read.
            var order: [(TrackFrame, Bool)] = []
            if referenceFirst, let reference { order.append((reference, true)) }
            if let previous { order.append((previous, false)) }
            if !referenceFirst, let reference, reference.capturedAt != previous?.capturedAt {
                order.append((reference, true))
            }
            var last: PaneMeasurement?
            for (base, fromReference) in order {
                let estimate = MotionEstimator.estimate(previous: base, current: frame)
                last = PaneMeasurement(frame: frame, estimate: estimate, fromReference: fromReference,
                                       ms: elapsedMs(since: start))
                if estimate.valid { break }
            }
            return last
        }.value
        guard let index = currentTrackerIndex(id: tracker.id, epoch: epoch, target: target, session: session) else {
            trackStats.dropped += 1
            return
        }
        guard let measured else { return }
        let wasLost = trackers[index].isLost
        trackers[index].apply(measured.estimate, frame: measured.frame, fromReference: measured.fromReference, now: Date())
        trackStats.recordFrame(at: captureStart)
        trackStats.lastEstimateMs = measured.ms
        if !wasLost, case .lost(let reason) = trackers[index].state {
            log(["event": "scroll_fallback", "reason": reason, "frames": trackers[index].frames])
        } else if wasLost, !trackers[index].isLost {
            trackStats.recoveries += 1
        }
        // The same capture refreshes this pane's blur (off the main actor, newest wins), so the cover
        // keeps up with scrolling instead of waiting for the next window thumbnail.
        if measured.estimate.valid, mode == .blur {
            paneCoverQueue.submit(image: image, tag: CoverTag(
                session: session, windowID: target.windowID, rect: cropRect, capturedAt: captureStart,
                radius: BlurRenderer.radiusPoints, paneTracker: tracker.id))
        }
        render()
    }

    private func currentTrackerIndex(id: Int, epoch: Int, target: TargetWindow, session: UInt64) -> Int? {
        guard isActive, session == sessionGeneration, let now = self.target, now.sameGeometry(as: target),
              let index = trackers.firstIndex(where: { $0.id == id }), trackers[index].epoch == epoch
        else { return nil }
        return index
    }

    // MARK: - Commit integration

    /// Called when a read commits. Panes still moving after its capture keep tracking relative to the
    /// new read; the rest are done. Covers for unscored content exposed by scrolling are held briefly.
    func reconcileTrackers(reference: TrackFrame?, captureStartedAt: Date) {
        trackingReference = reference
        guard !trackers.isEmpty || layoutChanged else { return }
        if !strictness.coversWholeWindow, let target {
            var held: [CGRect] = []
            for tracker in trackers where paneHasCover(tracker) {
                held += tracker.isLost ? [tracker.pane.viewport] : tracker.exposedRects + tracker.unreliableRects
            }
            if layoutChanged, regions.contains(where: { region in
                decisions[region.id]?.visibleIntent == false && !trackers.contains { $0.owns(region.rect) }
            }) {
                held.append(contentArea(target))
            }
            if !held.isEmpty { exposureHold = (held, Date().addingTimeInterval(Self.exposureHoldTime)) }
        }
        let continuing = trackers.filter { $0.lastActivityAt >= captureStartedAt }
        if continuing.count < trackers.count { logTracking(outcome: "reconciled") }
        trackers = continuing.map { tracker in
            var tracker = tracker
            let anchor = reference.flatMap { frame -> TrackFrame? in
                guard let target, frame.rect == target.visibleRect else { return nil }
                return frame.cropped(to: tracker.pane.viewport)?.masked(target.occluders.map(\.rect))
            }
            tracker.rebase(anchor: anchor, capturedAt: captureStartedAt, now: Date())
            return tracker
        }
        if !trackers.isEmpty { ensureTrackingLoop() }
        updateScrollStatus()
    }

    func paneHasCover(_ tracker: PaneTracker) -> Bool {
        regions.contains { tracker.owns($0.rect) && decisions[$0.id]?.visibleIntent == false }
    }

    /// Keeps a fragment cut by a pane edge on the semantic identity of the whole region it came from:
    /// the classifier input (and cached score) stays the full text that was read before, not a new
    /// input per visible fragment. Requires the fragment's text to be inside the old region's text and
    /// the old region's tracked position to overlap it.
    func inheritEdgeIdentity(_ fresh: [ScreenRegion], target: TargetWindow, capturedAt: Date) -> [ScreenRegion] {
        guard !regions.isEmpty else { return fresh }
        let content = contentArea(target)
        let edges = [content] + scrollPanes.map { $0.viewport.intersection(content) }.filter { !$0.isNull }
        // Only content that scrolled (or already kept its identity) qualifies, so text that was
        // really shortened in place doesn't inherit an old score.
        let previous = regions.compactMap { old -> (region: ScreenRegion, rect: CGRect)? in
            guard let tracker = trackers.first(where: { $0.owns(old.rect) }) else {
                return old.identityKept ? (old, old.rect) : nil
            }
            guard !tracker.isFixed(old.rect), let offset = tracker.offset(at: capturedAt) else {
                return (old, old.rect)
            }
            return (old, old.rect.offsetBy(dx: offset.dx, dy: offset.dy))
        }
        var usedIDs = Set(fresh.map(\.id))
        return fresh.map { region in
            guard region.text.count >= Self.minInheritedFragment,
                  edges.contains(where: { Self.touchesEdge(region.rect, of: $0) })
            else { return region }
            let match = previous.first { old in
                old.region.appName == region.appName && old.region.windowTitle == region.windowTitle
                    && old.region.text.count > region.text.count && old.region.text.contains(region.text)
                    && old.rect.overlapFraction(of: region.rect) >= 0.5
            }
            guard let old = match?.region else { return region }
            var copy = region
            copy.text = old.text
            copy.fingerprint = old.fingerprint
            copy.classifierFingerprint = old.classifierFingerprint
            var occurrence = 0
            while usedIDs.contains("\(old.fingerprint.prefix(10))-\(occurrence)") { occurrence += 1 }
            copy.id = "\(old.fingerprint.prefix(10))-\(occurrence)"
            copy.identityKept = true
            usedIDs.insert(copy.id)
            copy.reason += "; partly scrolled out — keeps the identity of the whole region"
            return copy
        }
    }

    static let minInheritedFragment = 12

    private static func touchesEdge(_ rect: CGRect, of pane: CGRect) -> Bool {
        guard pane.contains(rect.center) else { return false }
        let slack: CGFloat = 6 + Segmenter.padding
        return abs(rect.minY - pane.minY) <= slack || abs(rect.maxY - pane.maxY) <= slack
            || abs(rect.minX - pane.minX) <= slack || abs(rect.maxX - pane.maxX) <= slack
    }

    // MARK: - Placement

    /// Where geometry read at `rect` is drawn now.
    func placement(of rect: CGRect, now: Date) -> Placement {
        if let index = trackers.firstIndex(where: { $0.owns(rect) }) {
            let tracker = trackers[index]
            if case .lost = tracker.effectiveState(now: now) { return .unknown }
            guard let placed = tracker.place(rect) else { return .gone }
            return .moved(placed, margin: tracker.margin, tracker: index)
        }
        return layoutChanged ? .unknown : .fresh(rect)
    }

    /// Current position of a region for pointer hit-testing, if it is known.
    func currentRect(_ rect: CGRect) -> CGRect? {
        switch placement(of: rect, now: Date()) {
        case .fresh(let current), .moved(let current, _, _): return current
        case .unknown, .gone: return nil
        }
    }

    /// True when a new region's unscored content was exposed by scrolling moments ago.
    func heldAfterScroll(_ region: ScreenRegion, decision: RegionDecision?) -> Bool {
        guard let hold = exposureHold, Date() < hold.until, decision?.pDistracting == nil,
              decision?.overridden != true
        else { return false }
        return hold.areas.contains { $0.intersects(region.rect.insetBy(dx: 2, dy: 2)) }
    }

    /// Image shifts for scrolled panes, so the blurred cover moves with its content. Uses the pane's
    /// own capture when it's newer than the window image.
    func coverShifts() -> [OverlayScene.ImageShift] {
        let now = Date()
        paneCovers = paneCovers.filter { entry in trackers.contains { $0.id == entry.key } }
        return trackers.compactMap { tracker in
            if case .lost = tracker.effectiveState(now: now) { return nil }
            let pane = paneCovers[tracker.id].flatMap { $0.capturedAt > coverImageAt ? $0 : nil }
            guard let then = tracker.offset(at: pane?.capturedAt ?? coverImageAt) else {
                return OverlayScene.ImageShift(clip: tracker.pane.viewport, offset: nil, fixed: [])
            }
            let offset = CGVector(dx: tracker.displacement.dx - then.dx, dy: tracker.displacement.dy - then.dy)
            guard pane != nil || abs(offset.dx) >= 0.5 || abs(offset.dy) >= 0.5 else { return nil }
            return OverlayScene.ImageShift(
                clip: tracker.pane.viewport, offset: offset, fixed: tracker.fixedRects,
                image: pane?.image, imageRect: pane?.rect ?? .null)
        }
    }

    // MARK: - Cover images

    func coverArrived(_ cover: BlurredCover?, tag: CoverTag) {
        guard isActive, tag.session == sessionGeneration, let target, target.windowID == tag.windowID else { return }
        if let id = tag.paneTracker {
            guard let cover, trackers.contains(where: { $0.id == id }),
                  tag.capturedAt > paneCovers[id]?.capturedAt ?? .distantPast
            else { return }
            paneCovers[id] = (cover.image, tag.rect, tag.capturedAt)
            render()
            return
        }
        guard target.visibleRect == tag.rect, tag.capturedAt >= coverImageAt else { return }
        coverImage = cover?.image
        coverFill = cover?.fill ?? coverFill
        coverImageAt = tag.capturedAt
        coverStatus = "Rebuilt \(coverQueue.rendered) · \(coverQueue.superseded) superseded · "
            + String(format: "blur %.0f ms off the main thread", coverQueue.lastMs)
        render()
    }

    // MARK: - Status

    func updateScrollStatus() {
        guard !trackers.isEmpty else {
            if scrollStatus != "Not scrolling" { scrollStatus = "Not scrolling" }
            return
        }
        let now = Date()
        let parts = trackers.map { tracker -> String in
            let size = "\(Int(tracker.pane.viewport.width))×\(Int(tracker.pane.viewport.height))"
            let state: String
            switch tracker.effectiveState(now: now) {
            case .starting: state = "starting"
            case .tracking:
                state = "tracking (\(tracker.axis?.rawValue ?? "still")) Δ \(Int(tracker.displacement.dx)),"
                    + "\(Int(tracker.displacement.dy)) pt ±\(Int(tracker.margin))"
            case .lost(let reason): state = "fallback mask — \(reason)"
            }
            return "pane #\(tracker.id) (\(tracker.pane.role) \(size)): \(state)"
        }
        var text = parts.joined(separator: "; ")
        if trackStats.frames > 0 {
            text += String(format: " · %.0f ms/frame (capture %.0f, measure %.0f) · %d frames · %d recovered · %d stale dropped",
                           trackStats.intervalMs, trackStats.lastCaptureMs, trackStats.lastEstimateMs,
                           trackStats.frames, trackStats.recoveries, trackStats.dropped)
        }
        if text != scrollStatus { scrollStatus = text }
    }

    private func logTracking(outcome: String) {
        for tracker in trackers {
            var state = "tracking"
            if case .lost(let reason) = tracker.state { state = "lost: \(reason)" }
            log(["event": "scroll_track", "outcome": outcome, "pane_role": tracker.pane.role,
                 "frames": tracker.frames, "state": state, "axis": tracker.axis?.rawValue ?? "none",
                 "interval_ms": Int(trackStats.intervalMs), "dropped": trackStats.dropped])
        }
    }
}
