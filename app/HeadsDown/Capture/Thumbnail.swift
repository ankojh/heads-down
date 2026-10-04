import CoreGraphics
import Foundation

/// Small capture of the target window, taken every tick.
///
/// - The grayscale copy drives change detection: which areas changed since regions were read,
///   which are animating, and whether content has settled.
/// - The color image is the source for the cover: heavily blurred and upscaled, it hides the
///   window while staying current without any OCR.
/// - A tiny color grid decides when the cover needs rebuilding. It is separate from the gray
///   threshold so a color-only change refreshes the cover without counting as a content change.
///
/// Neither copy is precise enough to measure scrolling; that uses `TrackFrame`.
struct Thumbnail {
    static let width = 192
    static let cellSize = 8
    /// Mean absolute gray difference per cell (0–255) that counts as a change. Chosen so a blinking
    /// text caret at thumbnail scale stays below it while scrolled text does not. Heuristic.
    static let cellThreshold = 6.0
    static let appearanceColumns = 24
    /// Largest per-channel difference (0–255) in the color grid that leaves the cover as is.
    static let appearanceThreshold = 3

    let image: CGImage
    let pixels: [UInt8]
    let width: Int
    let height: Int
    /// RGBA, `appearanceColumns` wide, row-major.
    let appearance: [UInt8]
    /// Quartz global points covered.
    let rect: CGRect

    var columns: Int { (width + Self.cellSize - 1) / Self.cellSize }
    var rows: Int { (height + Self.cellSize - 1) / Self.cellSize }
    var cellCount: Int { columns * rows }

    struct Diff {
        let changedFraction: Double
        /// Cell indices (row-major) that changed.
        let changedCells: [Int]
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
        guard drawn, let appearance = Self.colorGrid(image, aspect: rect.height / max(1, rect.width)) else {
            return nil
        }
        // Bitmap memory row 0 is the top of the image.
        self.image = image
        self.appearance = appearance
        pixels = buffer
        width = thumbWidth
        height = thumbHeight
        self.rect = rect
    }

    /// True when the cover image should be rebuilt: visible colors changed, even if the gray
    /// change detector (which drives re-reading) saw nothing.
    func appearanceDiffers(from other: Thumbnail) -> Bool {
        guard other.appearance.count == appearance.count else { return true }
        for index in appearance.indices where abs(Int(appearance[index]) - Int(other.appearance[index])) > Self.appearanceThreshold {
            return true
        }
        return false
    }

    private static func colorGrid(_ image: CGImage, aspect: CGFloat) -> [UInt8]? {
        let columns = appearanceColumns
        let rows = max(4, min(64, Int((CGFloat(columns) * aspect).rounded())))
        var buffer = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        return drawn ? buffer : nil
    }

    func cellRect(_ index: Int) -> CGRect {
        let cell = Self.cellSize
        let x0 = (index % columns) * cell, y0 = (index / columns) * cell
        let x1 = min(width, x0 + cell), y1 = min(height, y0 + cell)
        let pointsPerPixelX = rect.width / CGFloat(width)
        let pointsPerPixelY = rect.height / CGFloat(height)
        return CGRect(
            x: rect.minX + CGFloat(x0) * pointsPerPixelX,
            y: rect.minY + CGFloat(y0) * pointsPerPixelY,
            width: CGFloat(x1 - x0) * pointsPerPixelX,
            height: CGFloat(y1 - y0) * pointsPerPixelY)
    }

    func diff(against other: Thumbnail) -> Diff {
        guard other.width == width, other.height == height, other.rect == rect else {
            return Diff(changedFraction: 1, changedCells: Array(0..<cellCount), changedRects: [rect])
        }
        let cell = Thumbnail.cellSize
        var changed: [Int] = []
        for index in 0..<cellCount {
            let x0 = (index % columns) * cell, y0 = (index / columns) * cell
            let x1 = min(width, x0 + cell), y1 = min(height, y0 + cell)
            var total = 0
            for yy in y0..<y1 {
                let base = yy * width
                for xx in x0..<x1 {
                    total += abs(Int(pixels[base + xx]) - Int(other.pixels[base + xx]))
                }
            }
            if Double(total) / Double((x1 - x0) * (y1 - y0)) > Thumbnail.cellThreshold {
                changed.append(index)
            }
        }
        return Diff(
            changedFraction: Double(changed.count) / Double(cellCount),
            changedCells: changed,
            changedRects: changed.map(cellRect))
    }
}
