import Accelerate
import CoreGraphics
import Foundation

/// Grayscale copy of a screen area at tracking resolution (at most 1 px per point), used only to
/// measure how scrolling content moved. Never shown, logged, or sent anywhere.
///
/// The same scale is used for the reference cut from a cycle's full capture and for the small live
/// captures taken while scrolling, so the two can be compared pixel for pixel.
struct TrackFrame {
    static let maxPixelsPerPoint: CGFloat = 1
    static let maxDimension: CGFloat = 1400

    /// Row-major, top-left origin, 0–255.
    private(set) var pixels: [Float]
    let width: Int
    let height: Int
    /// Quartz global points covered.
    let rect: CGRect
    /// When the capture of these pixels started.
    let capturedAt: Date

    var pixelsPerPoint: CGFloat { CGFloat(width) / max(1, rect.width) }

    /// Tracking scale for a window: one value per target so references and live crops match.
    static func pixelsPerPoint(for visibleRect: CGRect) -> CGFloat {
        min(maxPixelsPerPoint, maxDimension / max(1, max(visibleRect.width, visibleRect.height)))
    }

    /// Draws `image` (covering `rect`) at `pixelsPerPoint`, then blanks `masking` (Quartz points),
    /// e.g. windows above the target, so they never count as fixed content. `pixelSize` forces the
    /// exact size of the frame it will be compared with (rounding can differ by a pixel).
    init?(
        image: CGImage, rect: CGRect, pixelsPerPoint: CGFloat, capturedAt: Date, masking: [CGRect] = [],
        pixelSize: (width: Int, height: Int)? = nil
    ) {
        let width = pixelSize?.width ?? max(8, Int((rect.width * pixelsPerPoint).rounded()))
        let height = pixelSize?.height ?? max(8, Int((rect.height * pixelsPerPoint).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var floats = [Float](repeating: 0, count: width * height)
        vDSP.convertElements(of: bytes, to: &floats)
        self.init(pixels: floats, width: width, height: height, rect: rect, capturedAt: capturedAt)
        blank(masking)
    }

    private init(pixels: [Float], width: Int, height: Int, rect: CGRect, capturedAt: Date) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.rect = rect
        self.capturedAt = capturedAt
    }

    /// Quartz points → pixel rect (top-left origin), clipped to the frame.
    func pixelRect(fromQuartz quartz: CGRect) -> CGRect {
        let local = quartz.intersection(rect).offsetBy(dx: -rect.minX, dy: -rect.minY)
        guard !local.isNull else { return .null }
        let scaleX = CGFloat(width) / rect.width, scaleY = CGFloat(height) / rect.height
        return CGRect(x: local.minX * scaleX, y: local.minY * scaleY, width: local.width * scaleX,
                      height: local.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The part of this frame covering `sub` (Quartz points), at the same scale.
    func cropped(to sub: CGRect) -> TrackFrame? {
        let px = pixelRect(fromQuartz: sub)
        guard !px.isNull, px.width >= 8, px.height >= 8 else { return nil }
        let x0 = Int(px.minX), y0 = Int(px.minY), cropWidth = Int(px.width), cropHeight = Int(px.height)
        var out = [Float](repeating: 0, count: cropWidth * cropHeight)
        for row in 0..<cropHeight {
            let source = (y0 + row) * width + x0
            out.replaceSubrange(row * cropWidth..<(row + 1) * cropWidth, with: pixels[source..<source + cropWidth])
        }
        let scaleX = CGFloat(width) / rect.width, scaleY = CGFloat(height) / rect.height
        let quartz = CGRect(x: rect.minX + px.minX / scaleX, y: rect.minY + px.minY / scaleY,
                            width: px.width / scaleX, height: px.height / scaleY)
        return TrackFrame(pixels: out, width: cropWidth, height: cropHeight, rect: quartz, capturedAt: capturedAt)
    }

    /// Same frame with `rects` (Quartz points) set to zero.
    func masked(_ rects: [CGRect]) -> TrackFrame {
        var copy = self
        copy.blank(rects)
        return copy
    }

    /// Swaps rows and columns, so horizontal motion can be measured with the vertical estimator.
    func transposed() -> TrackFrame {
        var out = [Float](repeating: 0, count: pixels.count)
        vDSP_mtrans(pixels, 1, &out, 1, vDSP_Length(width), vDSP_Length(height))
        let swapped = CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        return TrackFrame(pixels: out, width: height, height: width, rect: swapped, capturedAt: capturedAt)
    }

    private mutating func blank(_ rects: [CGRect]) {
        for quartz in rects {
            let px = pixelRect(fromQuartz: quartz)
            guard !px.isNull, px.width > 0, px.height > 0 else { continue }
            let x0 = Int(px.minX), span = Int(px.width)
            for row in Int(px.minY)..<Int(px.maxY) {
                let start = row * width + x0
                pixels.replaceSubrange(start..<start + span, with: repeatElement(Float(0), count: span))
            }
        }
    }
}
