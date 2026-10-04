import CoreGraphics
import Foundation

/// Small grayscale capture of the target window used for cheap change detection.
/// Comparing cells tells the controller which regions moved or changed, so their overlays can be
/// dropped right away instead of waiting for the next OCR/classification cycle.
struct Thumbnail {
    static let width = 192
    static let cellSize = 8
    /// Mean absolute gray difference per cell (0–255) that counts as a change. Chosen so a blinking
    /// text caret at thumbnail scale stays below it while scrolled text does not. Heuristic.
    static let cellThreshold = 6.0

    let pixels: [UInt8]
    let width: Int
    let height: Int
    /// Quartz global points covered.
    let rect: CGRect

    struct Diff {
        let changedFraction: Double
        let changedRects: [CGRect]
    }

    init?(image: CGImage, rect: CGRect) {
        let thumbWidth = Thumbnail.width
        let thumbHeight = max(8, min(256, Int((CGFloat(thumbWidth) * rect.height / rect.width).rounded())))
        var buffer = [UInt8](repeating: 0, count: thumbWidth * thumbHeight)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: thumbWidth, height: thumbHeight, bitsPerComponent: 8,
                bytesPerRow: thumbWidth, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
            return true
        }
        guard drawn else { return nil }
        // Bitmap memory row 0 is the top of the image.
        pixels = buffer
        width = thumbWidth
        height = thumbHeight
        self.rect = rect
    }

    func diff(against other: Thumbnail) -> Diff {
        guard other.width == width, other.height == height, other.rect == rect else {
            return Diff(changedFraction: 1, changedRects: [rect])
        }
        let cell = Thumbnail.cellSize
        let cols = (width + cell - 1) / cell
        let rows = (height + cell - 1) / cell
        let pointsPerPixelX = rect.width / CGFloat(width)
        let pointsPerPixelY = rect.height / CGFloat(height)
        var changed: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let x0 = col * cell, y0 = row * cell
                let x1 = min(width, x0 + cell), y1 = min(height, y0 + cell)
                var total = 0
                for yy in y0..<y1 {
                    let base = yy * width
                    for xx in x0..<x1 {
                        total += abs(Int(pixels[base + xx]) - Int(other.pixels[base + xx]))
                    }
                }
                let mean = Double(total) / Double((x1 - x0) * (y1 - y0))
                if mean > Thumbnail.cellThreshold {
                    changed.append(CGRect(
                        x: rect.minX + CGFloat(x0) * pointsPerPixelX,
                        y: rect.minY + CGFloat(y0) * pointsPerPixelY,
                        width: CGFloat(x1 - x0) * pointsPerPixelX,
                        height: CGFloat(y1 - y0) * pointsPerPixelY))
                }
            }
        }
        return Diff(changedFraction: Double(changed.count) / Double(rows * cols), changedRects: changed)
    }
}
