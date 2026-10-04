import AppKit

/// Everything drawn over the selected display in one frame. Replaced atomically on each render.
struct OverlayScene {
    enum Cover {
        case none
        /// Dark fill (Dim mode).
        case dim
        /// Blurred image of the window, drawn into `rect` (Blur mode). `shifts` move parts of it
        /// with scrolled panes.
        case image(CGImage, rect: CGRect, shifts: [ImageShift], fill: CGColor?)
        /// Neutral fill when no cover image exists yet. Never leaves a gap.
        case placeholder
    }

    /// Draws the part of a cover image inside `clip` (a scrolled pane) moved by `offset`: the
    /// image was captured before the content moved that far. Only the overlap of the moved image
    /// is used; newly exposed parts get the placeholder rather than stretched edge pixels.
    /// `offset == nil` means the image can't be mapped to the pane's content: placeholder only.
    /// `fixed` areas (sticky headers, side columns) keep the unshifted image.
    struct ImageShift {
        let clip: CGRect
        let offset: CGVector?
        let fixed: [CGRect]
        /// A fresher blurred capture of just this pane (from scroll tracking), drawn into
        /// `imageRect` moved by `offset`, instead of the window image.
        var image: CGImage?
        var imageRect: CGRect = .null
    }

    /// One window's cover. Layers are drawn back to front; holes only affect their own layer.
    struct Layer {
        /// Areas to cover (Quartz global points): the whole window (Strict) or distracting regions.
        var coverAreas: [CGRect]
        var cover: Cover
        /// Areas punched back out: window chrome, controls, windows above, keep regions.
        var visibleRects: [CGRect]
    }

    struct Box {
        let rect: CGRect
        let label: String
        let color: NSColor
        let dashed: Bool
    }

    var layers: [Layer] = []
    var boxes: [Box] = []

    static let empty = OverlayScene()
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

    func update(displayID: CGDirectDisplayID, scene: OverlayScene) {
        if self.displayID != displayID { place(on: displayID) }
        view.scene = scene
        view.needsDisplay = true
    }

    func clear() {
        view.scene = .empty
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
    static let dimColor = NSColor.black.withAlphaComponent(0.88)
    static let placeholderColor = NSColor.windowBackgroundColor

    var scene = OverlayScene.empty
    var displayOrigin: CGPoint = .zero

    override var isFlipped: Bool { true }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        for layer in scene.layers { drawLayer(layer, ctx: ctx) }
        for box in scene.boxes { drawBox(box, in: local(box.rect)) }
    }

    /// Draws one window's cover in its own transparency layer, so its holes (chrome, controls,
    /// windows above it) don't erase covers of windows further back.
    private func drawLayer(_ layer: OverlayScene.Layer, ctx: CGContext) {
        if case .none = layer.cover { return }
        let areas = layer.coverAreas.map(local)
        guard let first = areas.first else { return }
        let envelope = areas.dropFirst().reduce(first) { $0.union($1) }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.clip(to: areas)
        drawCover(layer.cover, ctx: ctx, envelope: envelope)
        ctx.restoreGState()
        for rect in layer.visibleRects {
            let hole = local(rect).intersection(envelope)
            if !hole.isNull { ctx.clear(hole) }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawCover(_ cover: OverlayScene.Cover, ctx: CGContext, envelope: CGRect) {
        // Square edges so no readable sliver is left at corners.
        switch cover {
        case .none:
            break
        case .dim:
            Self.dimColor.setFill()
            envelope.fill()
        case .placeholder:
            Self.placeholderColor.setFill()
            envelope.fill()
        case .image(let image, let rect, let shifts, let fill):
            // Gaps are filled with the page's average color, not a dark placeholder.
            ctx.setFillColor(fill ?? Self.placeholderColor.cgColor)
            ctx.fill(envelope)
            let target = local(rect)
            drawImage(image, in: target, ctx: ctx)
            for shift in shifts {
                let pane = local(shift.clip)
                ctx.saveGState()
                ctx.clip(to: pane)
                ctx.setFillColor(fill ?? Self.placeholderColor.cgColor)
                ctx.fill(pane)
                let source = shift.image.map { _ in local(shift.imageRect) } ?? target
                if let offset = shift.offset {
                    let moved = source.offsetBy(dx: offset.dx, dy: offset.dy)
                    ctx.clip(to: pane.intersection(moved))
                    drawImage(shift.image ?? image, in: moved, ctx: ctx)
                }
                ctx.restoreGState()
                for fixed in shift.fixed {
                    ctx.saveGState()
                    ctx.clip(to: local(fixed).intersection(pane))
                    drawImage(shift.image ?? image, in: source, ctx: ctx)
                    ctx.restoreGState()
                }
            }
        }
    }

    private func drawImage(_ image: CGImage, in target: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // The view is flipped; draw the image upright.
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: target.size))
        ctx.restoreGState()
    }

    private func drawBox(_ box: OverlayScene.Box, in rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        if box.dashed { path.setLineDash([5, 3], count: 2, phase: 0) }
        box.color.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = NSAttributedString(string: box.label, attributes: attributes)
        let size = label.size()
        var badge = CGRect(x: rect.minX, y: rect.minY - size.height - 2, width: size.width + 8, height: size.height + 2)
        if badge.minY < 0 { badge.origin.y = rect.minY }
        box.color.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: badge.minX + 4, y: badge.minY + 1))
    }
}
