import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case emptyRect

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Selected display is not available for capture"
        case .emptyRect: return "Nothing to capture"
        }
    }
}

/// Captures visible pixels of one display area, always excluding Heads Down's own windows
/// (overlays, labels, inspector) via ScreenCaptureKit's filter rather than hide/show loops.
actor ScreenCapturer {
    private var content: SCShareableContent?
    private var fetchedAt = Date.distantPast

    func refreshContent(force: Bool = false) async throws -> SCShareableContent {
        if !force, let content, Date().timeIntervalSince(fetchedAt) < 3 { return content }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        content = fresh
        fetchedAt = Date()
        return fresh
    }

    func invalidate() {
        content = nil
    }

    /// Captures `rect` (Quartz global points) at `pixelsPerPoint`.
    func capture(
        rect: CGRect, displayID: CGDirectDisplayID, pixelsPerPoint: CGFloat
    ) async throws -> (CGImage, CaptureGeometry) {
        let shareable = try await refreshContent()
        guard let display = shareable.displays.first(where: { $0.displayID == displayID }) else {
            invalidate()
            throw CaptureError.displayNotFound
        }
        let ownApps = shareable.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let displayBounds = CGDisplayBounds(displayID)
        let crop = rect.integral.intersection(displayBounds)
        guard !crop.isNull, crop.width >= 8, crop.height >= 8 else { throw CaptureError.emptyRect }

        let config = SCStreamConfiguration()
        config.sourceRect = crop.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        config.width = max(8, Int((crop.width * pixelsPerPoint).rounded()))
        config.height = max(8, Int((crop.height * pixelsPerPoint).rounded()))
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let geometry = CaptureGeometry(
            displayID: displayID, displayBounds: displayBounds, cropRect: crop,
            pixelWidth: image.width, pixelHeight: image.height)
        return (image, geometry)
    }
}
