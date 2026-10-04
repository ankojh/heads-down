import CoreGraphics
import CoreImage
import Foundation

/// Builds the cover image from the latest small capture of a window: a strong Gaussian blur of
/// the real colors (no darkening), later drawn upscaled over the window.
///
/// Because the source is the ~192 px thumbnail refreshed every tick, the cover follows the real
/// content (≈ 2.5 fps) instead of freezing a stale snapshot. While a pane scrolls, the overlay
/// shifts the existing image with the measured displacement instead of waiting for a new one.
/// It is still not a live compositor blur. Starting parameters, not tuned values.
enum BlurRenderer {
    /// Thread-safe; shared by every render.
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Blur radius in screen points.
    static let radiusPoints: CGFloat = 22

    /// Sources sharper than this are downscaled first: a 22 pt blur leaves nothing finer anyway,
    /// and it keeps the blur cheap for the larger pane captures used while scrolling.
    static let maxPixelsPerPoint: CGFloat = 0.25

    static func cover(image: CGImage, rect: CGRect) -> BlurredCover? {
        var input = CIImage(cgImage: image)
        var pixelsPerPoint = CGFloat(image.width) / max(1, rect.width)
        if pixelsPerPoint > maxPixelsPerPoint {
            let scale = maxPixelsPerPoint / pixelsPerPoint
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            pixelsPerPoint = maxPixelsPerPoint
        }
        let extent = input.extent.integral
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radiusPoints * pixelsPerPoint))
            .cropped(to: extent)
        guard let blurred = context.createCGImage(output, from: extent) else { return nil }
        return BlurredCover(image: blurred, fill: meanColor(of: input))
    }

    /// The source's average color: fills areas the image can't cover (just-exposed strips), so they
    /// match the page instead of showing a dark placeholder.
    private static func meanColor(of input: CIImage) -> CGColor? {
        let average = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

/// A blurred cover image and the color to fill gaps with.
struct BlurredCover {
    let image: CGImage
    let fill: CGColor?
}

/// What a cover image was made from, so a late result can't land on another window or session.
struct CoverTag: Equatable {
    let session: UInt64
    let windowID: CGWindowID
    let rect: CGRect
    /// When the source thumbnail's capture started; maps the image to scroll displacement.
    let capturedAt: Date
    let radius: CGFloat
    /// Set for a scrolled pane's own cover (the pane's tracker), nil for the whole window.
    var paneTracker: Int?
}

/// Runs blur renders off the main actor: at most one in progress plus the newest pending source.
/// A newer source replaces the pending one (counted as superseded). Results come back on the main
/// actor; `cancelAll` makes anything still running or pending irrelevant.
@MainActor
final class CoverRenderQueue {
    var onImage: ((BlurredCover?, CoverTag) -> Void)?
    private(set) var rendered = 0
    private(set) var superseded = 0
    private(set) var lastMs: Double = 0

    private var running = false
    private var pending: (image: CGImage, tag: CoverTag)?
    private var generation: UInt64 = 0

    func submit(_ thumb: Thumbnail, tag: CoverTag) {
        submit(image: thumb.image, tag: tag)
    }

    func submit(image: CGImage, tag: CoverTag) {
        if running {
            if pending != nil { superseded += 1 }
            pending = (image, tag)
            return
        }
        start(image, tag: tag)
    }

    func cancelAll() {
        generation += 1
        pending = nil
    }

    private func start(_ image: CGImage, tag: CoverTag) {
        running = true
        let generation = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let start = Date()
            let cover = BlurRenderer.cover(image: image, rect: tag.rect)
            let ms = elapsedMs(since: start)
            await self?.finish(cover, tag: tag, generation: generation, ms: ms)
        }
    }

    private func finish(_ cover: BlurredCover?, tag: CoverTag, generation finished: UInt64, ms: Double) {
        running = false
        rendered += 1
        lastMs = ms
        if finished == generation { onImage?(cover, tag) }
        if let next = pending {
            pending = nil
            start(next.image, tag: next.tag)
        }
    }
}
