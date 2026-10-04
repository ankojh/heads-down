import CoreGraphics
import Foundation

/// The area Heads Down may cover: the target window's visible area minus its top chrome
/// (title bar, toolbar, tabs, address bar), so navigation and window controls stay usable.
/// Higher windows and keep regions are subtracted separately when drawing.
enum ContentEnvelope {
    /// Used until accessibility reports the window's layout, or when it can't.
    static let defaultTitleBar: CGFloat = 28
    /// Chrome taller than this fraction of the window is not believed.
    static let maxChromeFraction: CGFloat = 0.3

    struct Chrome {
        let windowID: CGWindowID
        /// Height of the visible strip from the window's top edge. Relative, so it follows the window.
        let height: CGFloat
        let note: String
    }

    /// Finds where content starts from AX layout: the top of the largest content area near the top
    /// of the window, else the bottom of a toolbar, else a default title-bar height.
    static func chrome(for target: TargetWindow, layout: [AXContainer]) -> Chrome {
        let visible = target.visibleRect
        let top = visible.minY
        let limit = top + maxChromeFraction * visible.height
        let contentRoles: Set<String> = ["AXWebArea", "AXScrollArea", "AXSplitGroup", "AXGroup"]

        let content = layout
            .filter { contentRoles.contains($0.role) && $0.rect.area >= 0.3 * visible.area }
            .filter { $0.rect.minY > top + 1 && $0.rect.minY <= limit }
            .max { $0.rect.area < $1.rect.area }
        if let content {
            return Chrome(
                windowID: target.windowID, height: content.rect.minY - top,
                note: "Top \(Int(content.rect.minY - top)) pt left visible (above the \(content.role))")
        }
        let toolbarBottom = layout
            .filter { $0.role == "AXToolbar" && $0.rect.minY <= limit && $0.rect.maxY <= limit }
            .map(\.rect.maxY)
            .max()
        if let toolbarBottom {
            return Chrome(
                windowID: target.windowID, height: toolbarBottom - top,
                note: "Top \(Int(toolbarBottom - top)) pt left visible (toolbar)")
        }
        return fallback(for: target, reason: "no toolbar/content layout found")
    }

    static func fallback(for target: TargetWindow, reason: String) -> Chrome {
        Chrome(
            windowID: target.windowID, height: defaultTitleBar,
            note: "Top \(Int(defaultTitleBar)) pt left visible (default; \(reason))")
    }

    /// Visible strip above the content (Quartz global points).
    static func chromeBand(_ chrome: Chrome, target: TargetWindow) -> CGRect {
        chromeBand(chrome, visible: target.visibleRect)
    }

    /// The coverable content area below the chrome strip. Also the fallback scroll pane when
    /// accessibility doesn't identify one.
    static func contentArea(_ chrome: Chrome, visible: CGRect) -> CGRect {
        let band = chromeBand(chrome, visible: visible)
        return CGRect(x: visible.minX, y: band.maxY, width: visible.width, height: max(0, visible.maxY - band.maxY))
    }

    static func chromeBand(_ chrome: Chrome, visible: CGRect) -> CGRect {
        let bottom = min(visible.minY + max(0, chrome.height), visible.maxY)
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: bottom - visible.minY)
    }
}
