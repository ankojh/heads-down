import Accelerate
import CoreGraphics
import Foundation

/// Measures how a scroll pane's content moved between two tracking frames.
///
/// Model: one translation per frame step, vertical or horizontal (not both). The pane is split into
/// a grid of cells and the shift is estimated per cell from compact row signatures (mean gray of a
/// few column buckets per row). Cells that agree on the consensus shift are "moving"; cells that
/// only match at zero while the rest moves are "fixed" (sticky headers, side columns inside the
/// pane); cells matching neither are "unreliable" (changed, animated, nested pane). Repetitive or
/// featureless content can't vote, so a single repeated text line can't decide the motion.
///
/// All thresholds are heuristic starting points, not measured values.
enum MotionEstimator {
    static let grid = 6
    static let bucketsPerCell = 8
    /// Largest step between two frames that still leaves enough overlap to verify.
    static let maxShiftFraction = 0.6
    static let maxShiftPixels = 480
    /// Mean absolute signature difference (0–255) that still counts as the same content.
    static let residualLimit: Float = 6
    /// A cell's best match must beat any other shift (more than 3 px away) by this factor to vote.
    static let ambiguityRatio: Float = 1.15
    static let ambiguitySlack: Float = 0.5
    /// Signature standard deviation below which a cell is treated as blank.
    static let minTexture: Float = 4
    /// Fraction of a cell's rows that must overlap the previous frame to be compared.
    static let minOverlap = 0.6
    /// Below this consensus shift (pixels), moving and fixed cells can't be told apart.
    static let fixedMinShift = 3

    enum CellClass {
        case moving, fixed, unreliable, blank
        /// Content entering the pane: not present in the previous frame.
        case entering
    }

    enum Axis: String {
        case vertical, horizontal
    }

    struct Estimate {
        var valid: Bool
        /// Content displacement in points (current minus previous).
        var shift: CGVector
        /// `grid × grid`, row-major in screen space (index = row * grid + column).
        var cells: [CellClass]
        var axis: Axis
        var reason: String

        static func invalid(_ reason: String) -> Estimate {
            Estimate(valid: false, shift: .zero, cells: Array(repeating: .unreliable, count: grid * grid),
                     axis: .vertical, reason: reason)
        }
    }

    /// Cell `index` of a grid laid over `rect`.
    static func cellRect(_ index: Int, in rect: CGRect) -> CGRect {
        let row = index / grid, column = index % grid
        let cellWidth = rect.width / CGFloat(grid), cellHeight = rect.height / CGFloat(grid)
        return CGRect(x: rect.minX + CGFloat(column) * cellWidth, y: rect.minY + CGFloat(row) * cellHeight,
                      width: cellWidth, height: cellHeight)
    }

    static func estimate(previous: TrackFrame, current: TrackFrame) -> Estimate {
        guard previous.width == current.width, previous.height == current.height,
              abs(previous.rect.minX - current.rect.minX) <= 2, abs(previous.rect.minY - current.rect.minY) <= 2
        else { return .invalid("pane moved or changed size") }
        guard current.width >= grid * bucketsPerCell, current.height >= grid * bucketsPerCell else {
            return .invalid("pane too small to track")
        }
        let vertical = estimateAxis(previous: previous, current: current)
        let verticalUnreliable = vertical.cells.filter { $0 == .unreliable }.count
        let textured = vertical.cells.filter { $0 != .blank }.count
        // "Still" with many disagreeing cells is what sideways motion looks like vertically.
        if vertical.valid, vertical.shift != 0 || verticalUnreliable * 5 <= textured {
            return vertical.screen(axis: .vertical, scale: current.pixelsPerPoint)
        }

        // Horizontal scrolling: the same estimator on transposed frames.
        let horizontal = estimateAxis(previous: previous.transposed(), current: current.transposed())
        if horizontal.valid, horizontal.shift != 0,
           horizontal.cells.filter({ $0 == .unreliable }).count < verticalUnreliable {
            return horizontal.screen(axis: .horizontal, scale: current.pixelsPerPoint)
        }
        if vertical.valid { return vertical.screen(axis: .vertical, scale: current.pixelsPerPoint) }
        return .invalid(vertical.reason)
    }

    // MARK: - One axis (rows of the given frames)

    /// Result in the frame's own orientation: `cells[strip * grid + band]`, strips along rows.
    private struct AxisEstimate {
        var valid: Bool
        var shift: Int
        var cells: [CellClass]
        var reason: String

        func screen(axis: Axis, scale: CGFloat) -> Estimate {
            var mapped = cells
            if axis == .horizontal {
                // Transposed strip = screen column, band = screen row.
                for strip in 0..<grid {
                    for band in 0..<grid { mapped[band * grid + strip] = cells[strip * grid + band] }
                }
            }
            let points = CGFloat(shift) / max(scale, 0.01)
            let vector = axis == .vertical ? CGVector(dx: 0, dy: points) : CGVector(dx: points, dy: 0)
            return Estimate(valid: valid, shift: vector, cells: mapped, axis: axis, reason: reason)
        }
    }

    private struct CellFit {
        var texture: Float
        var best: Int
        var bestCost: Float
        var secondCost: Float
        var unique: Bool
    }

    private static func estimateAxis(previous: TrackFrame, current: TrackFrame) -> AxisEstimate {
        let rows = current.height
        let buckets = bucketsPerCell
        let maxShift = min(maxShiftPixels, Int(Double(rows) * maxShiftFraction))
        let old = signatures(previous)
        let new = signatures(current)
        var scratch = [Float](repeating: 0, count: rows * buckets)

        func strip(_ index: Int) -> (Int, Int) { (index * rows / grid, (index + 1) * rows / grid) }

        func cost(band: Int, strip index: Int, shift: Int) -> Float? {
            let (top, bottom) = strip(index)
            // Current row r shows what previous row r - shift showed.
            let low = max(top, shift), high = min(bottom, rows + shift)
            let count = high - low
            guard count > 0, Double(count) >= minOverlap * Double(bottom - top) else { return nil }
            let length = count * buckets
            let total = meanAbsoluteDifference(
                old[band], from: (low - shift) * buckets, new[band], from: low * buckets, length: length,
                scratch: &scratch)
            return total
        }

        // 1. Fit each cell independently: coarse search, then refine around the best.
        var fits: [CellFit] = []
        for index in 0..<grid {
            let (top, bottom) = strip(index)
            for band in 0..<grid {
                let texture = deviation(new[band], rows: top..<bottom, buckets: buckets)
                var costs: [(Int, Float)] = []
                for shift in stride(from: -maxShift, through: maxShift, by: 2) {
                    if let value = cost(band: band, strip: index, shift: shift) { costs.append((shift, value)) }
                }
                guard var best = costs.min(by: { $0.1 < $1.1 }) else {
                    fits.append(CellFit(texture: texture, best: 0, bestCost: .infinity, secondCost: .infinity,
                                        unique: false))
                    continue
                }
                for shift in [best.0 - 1, best.0 + 1] {
                    if let value = cost(band: band, strip: index, shift: shift), value < best.1 { best = (shift, value) }
                }
                let second = costs.filter { abs($0.0 - best.0) > 3 }.map(\.1).min() ?? .infinity
                let unique = texture >= minTexture && best.1 <= residualLimit
                    && second > best.1 * ambiguityRatio + ambiguitySlack
                fits.append(CellFit(texture: texture, best: best.0, bestCost: best.1, secondCost: second,
                                    unique: unique))
            }
        }

        // 2. Consensus: the best-supported nonzero shift, else zero.
        let votes = fits.filter(\.unique).map(\.best)
        let textured = fits.filter { $0.texture >= minTexture }.count
        let moving = votes.filter { abs($0) >= 2 }
        let ranked = moving.map { vote in (vote: vote, support: moving.filter { abs($0 - vote) <= 1 }.count) }
        let leader = ranked.max { $0.support < $1.support || ($0.support == $1.support && $0.vote > $1.vote) }
        var consensus = 0
        if let leader, leader.support >= 2, leader.support * 3 >= votes.count {
            let support = moving.filter { abs($0 - leader.vote) <= 1 }.sorted()
            consensus = support[support.count / 2]
        } else if !votes.contains(where: { abs($0) <= 1 }), textured > 0 {
            let reason = votes.isEmpty
                ? "content repetitive or changed — motion ambiguous" : "no consistent motion across the pane"
            return AxisEstimate(valid: false, shift: 0, cells: fits.map { _ in .unreliable }, reason: reason)
        }

        // 3. Classify every cell against the consensus.
        var cells: [CellClass] = []
        var unreliable = 0
        for (offset, fit) in fits.enumerated() {
            let index = offset / grid, band = offset % grid
            if fit.texture < minTexture {
                cells.append(.blank)
                continue
            }
            guard let atConsensus = cost(band: band, strip: index, shift: consensus) else {
                cells.append(.entering)
                continue
            }
            let tolerance = fit.bestCost * ambiguityRatio + ambiguitySlack
            if atConsensus <= residualLimit, atConsensus <= tolerance {
                cells.append(.moving)
            } else if abs(consensus) >= fixedMinShift, let atZero = cost(band: band, strip: index, shift: 0),
                      atZero <= residualLimit, atZero <= tolerance {
                cells.append(.fixed)
            } else {
                cells.append(.unreliable)
                unreliable += 1
            }
        }
        if textured > 0, unreliable * 2 > textured {
            return AxisEstimate(valid: false, shift: consensus, cells: cells,
                                reason: "most of the pane changed — not a plain scroll")
        }
        return AxisEstimate(valid: true, shift: consensus, cells: cells, reason: "")
    }

    /// Per column band: `rows × bucketsPerCell` means, so a cell's rows are contiguous.
    private static func signatures(_ frame: TrackFrame) -> [[Float]] {
        let buckets = bucketsPerCell
        var result: [[Float]] = []
        result.reserveCapacity(grid)
        frame.pixels.withUnsafeBufferPointer { pixels in
            guard let base = pixels.baseAddress else { return }
            for band in 0..<grid {
                let left = band * frame.width / grid, right = (band + 1) * frame.width / grid
                var signature = [Float](repeating: 0, count: frame.height * buckets)
                for bucket in 0..<buckets {
                    let start = left + bucket * (right - left) / buckets
                    let end = left + (bucket + 1) * (right - left) / buckets
                    let span = vDSP_Length(max(1, end - start))
                    for row in 0..<frame.height {
                        var mean: Float = 0
                        vDSP_meanv(base + row * frame.width + start, 1, &mean, span)
                        signature[row * buckets + bucket] = mean
                    }
                }
                result.append(signature)
            }
        }
        return result
    }

    private static func meanAbsoluteDifference(
        _ lhs: [Float], from lhsStart: Int, _ rhs: [Float], from rhsStart: Int, length: Int, scratch: inout [Float]
    ) -> Float {
        var sum: Float = 0
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                scratch.withUnsafeMutableBufferPointer { tmp in
                    guard let leftBase = left.baseAddress, let rightBase = right.baseAddress,
                          let tmpBase = tmp.baseAddress else { return }
                    vDSP_vsub(leftBase + lhsStart, 1, rightBase + rhsStart, 1, tmpBase, 1, vDSP_Length(length))
                    vDSP_svemg(tmpBase, 1, &sum, vDSP_Length(length))
                }
            }
        }
        return sum / Float(length)
    }

    private static func deviation(_ signature: [Float], rows: Range<Int>, buckets: Int) -> Float {
        let slice = signature[rows.lowerBound * buckets..<rows.upperBound * buckets]
        guard !slice.isEmpty else { return 0 }
        let mean = vDSP.mean(slice)
        let meanSquare = vDSP.meanSquare(slice)
        return sqrt(max(0, meanSquare - mean * mean))
    }
}
