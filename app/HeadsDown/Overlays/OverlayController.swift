import AppKit

struct OverlayItem {
    enum Cover {
        case none
        case dim
        case blur(CGImage)
    }

    /// Quartz global points.
    let rect: CGRect
    let number: Int
    let cover: Cover
    let showBox: Bool
    let label: String
    let color: NSColor
    let uncertain: Bool
}

/// One borderless, transparent, click-through window over the selected display.
/// It never becomes key or main, so it can't take focus or keyboard input, and it is excluded from
/// Heads Down's own captures by the ScreenCaptureKit filter.
@MainActor
final class OverlayController {
    private var window: NSWindow?
    private let view = OverlayView()
    private var displayID: CGDirectDisplayID?

    /// Window numbers to ignore when looking for the target window.
    var windowIDs: Set<CGWindowID> {
        guard let window, window.windowNumber > 0 else { return [] }
        return [CGWindowID(window.windowNumber)]
    }

    func show(displayID: CGDirectDisplayID) {
        let window = self.window ?? makeWindow()
        self.window = window
        place(on: displayID)
        window.orderFrontRegardless()
    }

    func update(displayID: CGDirectDisplayID, items: [OverlayItem]) {
        if self.displayID != displayID { place(on: displayID) }
        view.items = items
        view.needsDisplay = true
    }

    func clear() {
        view.items = []
        view.needsDisplay = true
    }

    func hide() {
        clear()
        window?.orderOut(nil)
    }

    func screenParametersChanged() {
        if let displayID { place(on: displayID) }
    }

    private func place(on displayID: CGDirectDisplayID) {
        guard let window else { return }
        self.displayID = displayID
        let quartz = CGDisplayBounds(displayID)
        window.setFrame(Geometry.quartzRectToAppKit(quartz), display: true)
        view.displayOrigin = quartz.origin
    }

    private func makeWindow() -> NSWindow {
        let window = OverlayWindow(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = view
        return window
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Flipped view covering exactly one display, so a Quartz global rect maps to view coordinates by
/// subtracting the display origin (see Capture/Geometry.swift).
private final class OverlayView: NSView {
    var items: [OverlayItem] = []
    var displayOrigin: CGPoint = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        for item in items {
            let rect = item.rect.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
            switch item.cover {
            case .none:
                break
            case .dim:
                NSColor.black.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            case .blur(let image):
                ctx.saveGState()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                // The view is flipped; draw the image upright.
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }
            if item.showBox { drawBox(item, in: rect) }
        }
    }

    private func drawBox(_ item: OverlayItem, in rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        if item.uncertain { path.setLineDash([5, 3], count: 2, phase: 0) }
        item.color.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = NSAttributedString(string: item.label, attributes: attributes)
        let size = label.size()
        var badge = CGRect(x: rect.minX, y: rect.minY - size.height - 2, width: size.width + 8, height: size.height + 2)
        if badge.minY < 0 { badge.origin.y = rect.minY }
        item.color.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: badge.minX + 4, y: badge.minY + 1))
    }
}
