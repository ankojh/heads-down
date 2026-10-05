import AppKit

/// Runs production controller logic with synthetic regions/frames: no capture, model requests,
/// event monitors, or app launch. See scripts/test-cover-continuity.sh.
@main
struct CoverContinuityChecks {
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    static func window(occluders: [Occluder] = [], rect: CGRect = bounds) -> TargetWindow {
        TargetWindow(windowID: 42, pid: 1, appName: "Test", bundleID: nil, title: "Test",
                     bounds: rect, visibleRect: rect, displayID: 1, occluders: occluders, ignoredOverlays: [])
    }

    static func region(_ id: String, _ rect: CGRect) -> ScreenRegion {
        ScreenRegion(id: id, number: 1, rect: rect, text: id, appName: "Test", windowTitle: "Test",
                     sources: [.ocr], observationCount: 1, reason: "test", fingerprint: id,
                     classifierFingerprint: id, geometryUncertain: false, windowID: 42)
    }

    @MainActor
    static func main() {
        // Keep test preferences in memory and never load cloud credentials.
        UserDefaults.standard.setVolatileDomain(
            ["classifierProvider": "laya", "strictness": "balanced"], forName: UserDefaults.argumentDomain)
        let controller = SessionController()
        controller.target = window()
        let now = Date()
        let old = region("old", CGRect(x: 100, y: 300, width: 200, height: 60))
        let replacement = region("replacement", old.rect)
        let unrelated = region("unrelated", CGRect(x: 500, y: 300, width: 100, height: 60))
        controller.regions = [old]
        controller.scoreCache.set(controller.cacheKey(old, revision: 0), 0.9)
        controller.rebuildDecisions()
        precondition(controller.decisions[old.id]?.visibleIntent == false)

        func commit(_ regions: [ScreenRegion], at: Date = now) {
            controller.pendingCoverIDs = controller.pendingCovers(for: regions, capturedAt: at)
            controller.regions = regions
            controller.rebuildDecisions()
        }

        // Hover/OCR regrouping cannot reveal a covered card while its new input is pending.
        commit([replacement, unrelated])
        precondition(controller.decisions[replacement.id]?.visibleIntent == false)
        precondition(controller.decisions[replacement.id]?.pDistracting == nil)
        precondition(controller.decisions[replacement.id]?.verdict == .unknown)
        precondition(controller.decisions[unrelated.id]?.visibleIntent == true)
        let next = region("regrouped-again", old.rect)
        commit([next, unrelated], at: now.addingTimeInterval(10))
        precondition(controller.decisions[next.id]?.visibleIntent == false, "Must outlast the old 4s timer")
        controller.scoreCache.set(controller.cacheKey(next, revision: 0), 0.1)
        controller.rebuildDecisions()
        precondition(controller.decisions[next.id]?.visibleIntent == true)
        precondition(!controller.pendingCoverIDs.contains(next.id))

        // An explicit reveal wins over pending coverage.
        controller.pendingCoverIDs = [replacement.id]
        controller.regions = [replacement]
        controller.overrides.reveal(revision: 0, fingerprint: replacement.fingerprint)
        controller.rebuildDecisions()
        precondition(controller.decisions[replacement.id]?.visibleIntent == true)
        precondition(controller.pendingCoverIDs.isEmpty)
        controller.overrides.clear()

        // Read-time scroll geometry, not the newer displacement at commit time, is transferred.
        let pane = ScrollPane(viewport: bounds, role: "test", fromAX: false)
        let image = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 80,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.makeImage()!
        func frame(_ time: Date) -> TrackFrame {
            TrackFrame(image: image, rect: bounds, pixelsPerPoint: 0.1, capturedAt: time)!
        }
        var tracker = PaneTracker(id: 1, pane: pane, pixelsPerPoint: 0.1, reference: frame(now),
                                  motionStartedAt: now, now: now)
        if case .lost = tracker.effectiveState(now: now) {} else {
            preconditionFailure("Scroll startup must mask immediately, not leave covers at old positions")
        }
        controller.regions = [old]
        controller.rebuildDecisions()
        controller.trackers = [tracker]
        precondition(controller.pendingCovers(for: [unrelated], capturedAt: now) == [unrelated.id])
        let capture = now.addingTimeInterval(1)
        let later = now.addingTimeInterval(2)
        func estimate(_ dy: CGFloat) -> MotionEstimator.Estimate {
            .init(valid: true, shift: CGVector(dx: 0, dy: dy),
                  cells: Array(repeating: .moving, count: MotionEstimator.grid * MotionEstimator.grid),
                  axis: .vertical, reason: "test")
        }
        tracker.apply(estimate(-100), frame: frame(capture), fromReference: true, now: capture)
        tracker.apply(estimate(-200), frame: frame(later), fromReference: true, now: later)
        controller.trackers = [tracker]
        controller.regions = [old]
        controller.rebuildDecisions()
        let moved = region("moved", old.rect.offsetBy(dx: 0, dy: -100))
        let exposed = region("exposed", CGRect(x: 100, y: 550, width: 200, height: 40))
        let notCovered = region("not-covered", CGRect(x: 100, y: 100, width: 200, height: 40))
        let held = controller.pendingCovers(for: [moved, exposed, notCovered], capturedAt: capture)
        precondition(held == [moved.id, exposed.id])
        commit([moved, exposed], at: capture)
        precondition(controller.paneHasCover(tracker), "Pending coverage must survive ongoing tracking")

        // Lost tracking holds the pane; all-visible panes must not gain a mask.
        tracker.markLost("test")
        controller.trackers = [tracker]
        precondition(controller.pendingCovers(for: [unrelated], capturedAt: later) == [unrelated.id])
        controller.pendingCoverIDs = []
        controller.regions = [unrelated]
        controller.rebuildDecisions()
        precondition(controller.pendingCovers(for: [replacement], capturedAt: later).isEmpty)

        // Popups only change clipping. True moves still invalidate geometry, and stale captures
        // with different occlusion must still be rejected by sameGeometry.
        let tooltip = window(occluders: [Occluder(rect: old.rect, owner: "Tooltip", layer: 10)])
        precondition(window().sameFrame(as: tooltip))
        precondition(!window().sameGeometry(as: tooltip))
        precondition(!window().sameFrame(as: window(rect: bounds.offsetBy(dx: 10, dy: 0))))
        controller.invalidateAll()
        precondition(controller.pendingCoverIDs.isEmpty)
        print("PASS: cover continuity (hover, repeated reads, score/reveal release, scroll, lost tracking, occlusion)")
    }
}
