import AppKit
import CoreGraphics

/// Coordinate conversions, kept in one place.
///
/// Canonical space for all region geometry: **Quartz global display coordinates in points**.
/// Origin is the top-left of the main display, y grows downward, and other displays may have
/// negative coordinates. CGWindowList bounds and Accessibility positions already use this space.
///
/// Other spaces and how they convert:
/// - AppKit screen coordinates: origin bottom-left of the main display, y grows upward.
/// - ScreenCaptureKit `sourceRect`: points relative to the captured display's top-left.
/// - Captured images: pixels, top-left origin, covering `CaptureGeometry.cropRect`.
/// - Vision boxes: normalized to the analyzed image, bottom-left origin.
/// - Overlay view: flipped NSView covering exactly one display, so display-local points.
enum Geometry {
    static var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func appKitPointToQuartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    static func quartzRectToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func displayLocal(_ rect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        let display = CGDisplayBounds(displayID)
        return rect.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    @MainActor
    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screenID($0) == id }
    }

    @MainActor
    static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @MainActor
    static func backingScale(for id: CGDirectDisplayID) -> CGFloat {
        screen(for: id)?.backingScaleFactor ?? 2
    }
}

/// Describes how one captured image maps back to the canonical space.
struct CaptureGeometry {
    let displayID: CGDirectDisplayID
    /// Display bounds in Quartz global points at capture time.
    let displayBounds: CGRect
    /// Captured area in Quartz global points.
    let cropRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    var scaleX: CGFloat { CGFloat(pixelWidth) / cropRect.width }
    var scaleY: CGFloat { CGFloat(pixelHeight) / cropRect.height }

    /// Vision normalized box (bottom-left origin) → Quartz global points.
    func quartzRect(fromVisionNormalized norm: CGRect) -> CGRect {
        CGRect(
            x: cropRect.minX + norm.minX * cropRect.width,
            y: cropRect.minY + (1 - norm.maxY) * cropRect.height,
            width: norm.width * cropRect.width,
            height: norm.height * cropRect.height)
    }

    /// Geometry for a sub-crop of this image (pixel rect, top-left origin). Used for banded OCR.
    func subGeometry(pixelRect pixels: CGRect) -> CaptureGeometry {
        let quartz = CGRect(
            x: cropRect.minX + pixels.minX / scaleX, y: cropRect.minY + pixels.minY / scaleY,
            width: pixels.width / scaleX, height: pixels.height / scaleY)
        return CaptureGeometry(
            displayID: displayID, displayBounds: displayBounds, cropRect: quartz,
            pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height))
    }

    /// Quartz global points → pixel rect in the captured image (top-left origin), clipped.
    func pixelRect(fromQuartz rect: CGRect) -> CGRect {
        let local = rect.intersection(cropRect).offsetBy(dx: -cropRect.minX, dy: -cropRect.minY)
        guard !local.isNull else { return .null }
        let px = CGRect(
            x: local.minX * scaleX, y: local.minY * scaleY,
            width: local.width * scaleX, height: local.height * scaleY
        ).integral
        return px.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }
}
