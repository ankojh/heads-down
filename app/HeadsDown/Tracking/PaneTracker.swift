import CoreGraphics
import Foundation

/// A scrolling container in the front window.
struct ScrollPane {
    /// Visible viewport (Quartz points), clipped to the content envelope.
    let viewport: CGRect
    /// AX role it came from, or "content area" when no usable AX scroll area contains the pointer.
    let role: String
    let fromAX: Bool

    func sameArea(as other: ScrollPane) -> Bool {
        abs(viewport.minX - other.viewport.minX) <= 2 && abs(viewport.minY - other.viewport.minY) <= 2
            && abs(viewport.width - other.viewport.width) <= 2 && abs(viewport.height - other.viewport.height) <= 2
    }
}

/// Geometry-only tracking of one scrolled pane between screen reads.
///
/// Semantics never change here: regions keep their text, fingerprints, and scores; only where they
/// are drawn moves. Displacement is measured from frames (see MotionEstimator), relative to the
/// frame the current regions were read from, and reset by every committed re-read.
struct PaneTracker {
    enum State: Equatable {
        case starting
        case tracking
        case lost(String)
    }

    /// Screen-space role of one grid cell over the viewport, accumulated while content moves.
    enum CellState {
        case unknown, moving, fixed
        /// Was fixed and moving at different times (a header becoming sticky, a reflow).
        case conflicted
    }

    /// Before the first measurement, covers stay where they were (grown by the margin) this long.
    static let startGrace: TimeInterval = 0.5
    /// Tracking without a committed re-read is not trusted longer than this.
    static let maxAnchorAge: TimeInterval = 30
    static let baseMargin: CGFloat = 4
    static let maxMargin: CGFloat = 24
    static let historyLimit = 64

    let id: Int
    let pane: ScrollPane
    let pixelsPerPoint: CGFloat
    /// Bumped on every rebase, so measurements against an older reference are discarded.
    private(set) var epoch = 0
    private(set) var state: State
    /// Last frame whose position relative to the regions' read is known.
    private(set) var previous: TrackFrame?
    /// Frame the current regions were read from. Measuring against it gives the displacement
    /// directly, so a failed step (or a lost tracker) can recover while the pane still overlaps it.
    private(set) var reference: TrackFrame?
    /// Content displacement since the current regions were read (points).
    private(set) var displacement = CGVector.zero
    private(set) var history: [(at: Date, offset: CGVector)]
    private(set) var cells = [CellState](repeating: .unknown, count: MotionEstimator.grid * MotionEstimator.grid)
    private(set) var unreliableNow: Set<Int> = []
    private(set) var stepsSinceAnchor = 0
    private var extraMargin: CGFloat = 0
    let startedAt: Date
    private(set) var anchoredAt: Date
    var lastWheelAt: Date
    /// Capture time of the last frame that showed movement.
    private(set) var lastMovedAt: Date
    private(set) var quietFrames = 0
    private(set) var axis: MotionEstimator.Axis?
    private(set) var frames = 0

    /// `motionStartedAt`: when movement began, if known (the first wheel event). Content is assumed
    /// unmoved before it, so cover images captured earlier map to zero displacement.
    init(id: Int, pane: ScrollPane, pixelsPerPoint: CGFloat, reference: TrackFrame?, motionStartedAt: Date?, now: Date) {
        self.id = id
        self.pane = pane
        self.pixelsPerPoint = pixelsPerPoint
        previous = reference
        self.reference = reference
        state = reference == nil ? .lost("no reference frame from the last read") : .starting
        history = [(reference?.capturedAt ?? now, .zero)]
        if let motionStartedAt, motionStartedAt > history[0].at { history.append((motionStartedAt, .zero)) }
        startedAt = now
        anchoredAt = now
        lastWheelAt = now
        lastMovedAt = .distantPast
    }

    var isLost: Bool {
        if case .lost = state { return true }
        return false
    }

    /// What rendering should assume: a tracker that hasn't measured anything in time counts as lost.
    func effectiveState(now: Date) -> State {
        if state == .starting, now.timeIntervalSince(startedAt) > Self.startGrace {
            return .lost("no measurement yet")
        }
        return state
    }

    /// Conservative slack around tracked rectangles: grows with measurement steps since the last read.
    var margin: CGFloat {
        min(Self.maxMargin, Self.baseMargin + 0.5 * CGFloat(stepsSinceAnchor) + extraMargin)
    }

    var lastActivityAt: Date { max(lastWheelAt, lastMovedAt) }

    /// Worth capturing for: recently scrolled or still moving (momentum), and measurable.
    func wantsFrames(now: Date, quiet: TimeInterval) -> Bool {
        guard previous != nil || reference != nil else { return false }
        if isLost, reference == nil { return false }
        return now.timeIntervalSince(lastWheelAt) < quiet || quietFrames < 2
    }

    /// Measure against the reference first: lost, never measured from a frame, or just rebased
    /// (the interpolated displacement is approximate until the reference confirms it).
    var prefersReference: Bool { isLost || previous == nil || extraMargin > 0 }

    func owns(_ rect: CGRect) -> Bool { pane.viewport.contains(rect.center) }

    func cellRect(_ index: Int) -> CGRect { MotionEstimator.cellRect(index, in: pane.viewport) }

    private func cell(containing point: CGPoint) -> Int? {
        cells.indices.first { cellRect($0).contains(point) }
    }

    var fixedRects: [CGRect] { cells.indices.filter { cells[$0] == .fixed }.map(cellRect) }

    var unreliableRects: [CGRect] {
        cells.indices.filter { cells[$0] == .conflicted || unreliableNow.contains($0) }.map(cellRect)
    }

    /// Parts of the viewport showing content that wasn't on screen when the regions were read.
    var exposedRects: [CGRect] {
        guard displacement != .zero else { return [] }
        return pane.viewport.subtracting(pane.viewport.offsetBy(dx: displacement.dx, dy: displacement.dy))
    }

    /// Where content read at `rect` is now, clipped to the viewport; nil once it has scrolled out.
    /// Content in cells measured as fixed (sticky headers, side columns) stays put.
    func place(_ rect: CGRect) -> CGRect? {
        let fixed = cell(containing: rect.center).map { cells[$0] == .fixed } ?? false
        let moved = fixed ? rect : rect.offsetBy(dx: displacement.dx, dy: displacement.dy)
        let clipped = moved.intersection(pane.viewport)
        return clipped.isNull || clipped.width < 2 || clipped.height < 2 ? nil : clipped
    }

    func isFixed(_ rect: CGRect) -> Bool {
        cell(containing: rect.center).map { cells[$0] == .fixed } ?? false
    }

    /// Displacement at a past moment (linear between measurements); nil before the first one.
    func offset(at time: Date) -> CGVector? {
        guard let first = history.first, time >= first.at else { return nil }
        guard let afterIndex = history.firstIndex(where: { $0.at > time }) else { return history.last?.offset }
        let before = history[afterIndex - 1], after = history[afterIndex]
        let span = after.at.timeIntervalSince(before.at)
        let fraction = span > 0 ? CGFloat(time.timeIntervalSince(before.at) / span) : 1
        return CGVector(dx: before.offset.dx + (after.offset.dx - before.offset.dx) * fraction,
                        dy: before.offset.dy + (after.offset.dy - before.offset.dy) * fraction)
    }

    /// Applies one measurement. `fromReference` means it was taken against the regions' own read
    /// frame, so it replaces the accumulated displacement instead of adding to it (and recovers a
    /// lost tracker).
    mutating func apply(_ estimate: MotionEstimator.Estimate, frame: TrackFrame, fromReference: Bool, now: Date) {
        frames += 1
        guard estimate.valid else {
            state = .lost(estimate.reason)
            return
        }
        if isLost, !fromReference { return }
        let step: CGVector
        if fromReference {
            step = CGVector(dx: estimate.shift.dx - displacement.dx, dy: estimate.shift.dy - displacement.dy)
            displacement = estimate.shift
            extraMargin = 0
        } else {
            step = estimate.shift
            displacement = CGVector(dx: displacement.dx + step.dx, dy: displacement.dy + step.dy)
        }
        previous = frame
        history.append((frame.capturedAt, displacement))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }

        let pixels = max(abs(estimate.shift.dx), abs(estimate.shift.dy)) * pixelsPerPoint
        if max(abs(step.dx), abs(step.dy)) * pixelsPerPoint >= 1 {
            stepsSinceAnchor += 1
            lastMovedAt = frame.capturedAt
            quietFrames = 0
            axis = estimate.axis
        } else {
            quietFrames += 1
        }
        unreliableNow = Set(estimate.cells.indices.filter { estimate.cells[$0] == .unreliable })
        if pixels >= CGFloat(MotionEstimator.fixedMinShift) {
            for (index, observed) in estimate.cells.enumerated() {
                switch (observed, cells[index]) {
                case (.moving, .fixed), (.fixed, .moving): cells[index] = .conflicted
                case (.moving, .unknown): cells[index] = .moving
                case (.fixed, .unknown): cells[index] = .fixed
                default: break
                }
            }
        }
        state = now.timeIntervalSince(anchoredAt) > Self.maxAnchorAge
            ? .lost("tracked too long without a re-read") : .tracking
    }

    mutating func markLost(_ reason: String) {
        state = .lost(reason)
    }

    /// A read committed mid-scroll: displacement restarts from the frame it was captured at.
    /// History is shifted so cover images captured earlier still map correctly.
    mutating func rebase(anchor newAnchor: TrackFrame?, capturedAt: Date, now: Date) {
        epoch += 1
        anchoredAt = now
        stepsSinceAnchor = 0
        for index in cells.indices where cells[index] == .conflicted { cells[index] = .unknown }
        unreliableNow = []
        reference = newAnchor
        if isLost {
            // Position relative to the old read is unknown; only the new reference can re-establish it.
            displacement = .zero
            previous = nil
            history = [(capturedAt, .zero)]
            extraMargin = 0
            state = newAnchor == nil ? .lost("no reference frame from the last read") : .lost("re-anchoring")
            return
        }
        let base = offset(at: capturedAt) ?? displacement
        // Interpolation between two measurements is only approximate until the anchor confirms it.
        let after = history.first { $0.at > capturedAt }?.offset ?? displacement
        extraMargin = min(Self.maxMargin, hypot(after.dx - base.dx, after.dy - base.dy))
        history = history.map { ($0.at, CGVector(dx: $0.offset.dx - base.dx, dy: $0.offset.dy - base.dy)) }
        displacement = CGVector(dx: displacement.dx - base.dx, dy: displacement.dy - base.dy)
    }
}

extension CGRect {
    /// This rectangle minus `other`, as up to four non-overlapping rectangles.
    func subtracting(_ other: CGRect) -> [CGRect] {
        let cut = intersection(other)
        guard !cut.isNull, cut.area > 0 else { return [self] }
        let pieces = [
            CGRect(x: minX, y: minY, width: width, height: cut.minY - minY),
            CGRect(x: minX, y: cut.maxY, width: width, height: maxY - cut.maxY),
            CGRect(x: minX, y: cut.minY, width: cut.minX - minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: maxX - cut.maxX, height: cut.height),
        ]
        return pieces.filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}
