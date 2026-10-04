import CoreGraphics
import CoreImage

/// Blurs a region of an already-captured clean frame. The overlay then shows this processed
/// snapshot; it is not a live compositor blur, so moving content under it looks frozen until the
/// next cycle (or until change detection removes it).
enum BlurRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Blur radius in points; scaled to the capture's pixel density.
    static let radiusPoints: CGFloat = 10

    static func blurredCrop(of image: CGImage, geometry: CaptureGeometry, rect: CGRect) -> CGImage? {
        let pixels = geometry.pixelRect(fromQuartz: rect)
        guard !pixels.isNull, pixels.width >= 2, pixels.height >= 2, let crop = image.cropping(to: pixels)
        else { return nil }
        let input = CIImage(cgImage: crop)
        // Clamp so edge pixels repeat instead of fading to transparent or sampling outside content.
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radiusPoints * geometry.scaleX))
            .cropped(to: input.extent)
        return context.createCGImage(blurred, from: input.extent)
    }
}
