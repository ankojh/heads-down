import AppKit
import CoreGraphics

enum TargetSkip: Error, Equatable {
    case noWindow
    case offDisplay(String)
    case fullScreen(String)
    case mostlyOccluded(String)

    var message: String {
        switch self {
        case .noWindow:
            return "No normal app window on the selected display"
        case .offDisplay(let app):
            return "\(app)'s front window is mostly on another display — not covered"
        case .fullScreen(let app):
            return "\(app) is full screen — full-screen windows aren't covered yet"
        case .mostlyOccluded(let app):
            return "\(app)'s window is mostly covered by other windows — skipped"
        }
    }
}

/// Finds the frontmost normal window on one display, plus the windows stacked above it.
///
/// First-milestone scope: only this one window is analyzed. Areas covered by higher windows are
/// skipped rather than guessed at.
@MainActor
enum WindowLocator {
    static let minWindowSize = CGSize(width: 200, height: 120)
    /// Windows at or above this layer (screen-saver / assistive overlay levels) are commonly
    /// transparent click-through overlays from utilities. They are reported, not treated as occluders.
    static let ignoredOverlayLayer = 1000

    static func locate(
        displayID: CGDirectDisplayID, ignoring ignoredWindowIDs: Set<CGWindowID>
    ) -> Result<TargetWindow, TargetSkip> {
        let display = CGDisplayBounds(displayID)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return .failure(.noWindow)
        }
        let ownPID = getpid()
        var above: [Occluder] = []

        // The list is ordered front to back.
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if ignoredWindowIDs.contains(number) { continue }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            if alpha < 0.01 || !bounds.intersects(display) { continue }
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            let pid = (info[kCGWindowOwnerPID as String] as? pid_t) ?? 0
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? "Unknown app"

            let isCandidate = layer == 0 && pid != ownPID
                && bounds.width >= minWindowSize.width && bounds.height >= minWindowSize.height
            guard isCandidate else {
                // Heads Down's own inspector/control windows count as occluders too.
                above.append(Occluder(rect: bounds, owner: owner, layer: layer))
                continue
            }

            let onDisplay = bounds.intersection(display)
            if onDisplay.area < 0.5 * bounds.area { return .failure(.offDisplay(owner)) }
            if abs(bounds.minX - display.minX) <= 1, abs(bounds.minY - display.minY) <= 1,
               abs(bounds.width - display.width) <= 1, abs(bounds.height - display.height) <= 1 {
                return .failure(.fullScreen(owner))
            }

            let visible = onDisplay.integral.intersection(display)
            var occluders: [Occluder] = []
            var ignored: [Occluder] = []
            for item in above {
                let clipped = item.rect.intersection(visible)
                guard !clipped.isNull, clipped.area > 0 else { continue }
                let entry = Occluder(rect: clipped, owner: item.owner, layer: item.layer)
                if item.layer >= ignoredOverlayLayer { ignored.append(entry) } else { occluders.append(entry) }
            }
            let occludedArea = occluders.reduce(CGFloat(0)) { $0 + $1.rect.area }
            if occludedArea >= 0.9 * visible.area { return .failure(.mostlyOccluded(owner)) }

            let title = (info[kCGWindowName as String] as? String) ?? ""
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return .success(TargetWindow(
                windowID: number, pid: pid, appName: owner, bundleID: bundleID, title: title,
                bounds: bounds, visibleRect: visible, displayID: displayID,
                occluders: occluders, ignoredOverlays: ignored))
        }
        return .failure(.noWindow)
    }

    struct StackWindow {
        let id: CGWindowID
        let bounds: CGRect
        let layer: Int
    }

    /// On-screen windows overlapping the display, front to back (Heads Down's overlay excluded).
    /// Used to keep covers on windows that are no longer frontmost and to clip them correctly.
    static func stack(displayID: CGDirectDisplayID, ignoring ignoredWindowIDs: Set<CGWindowID>) -> [StackWindow] {
        let display = CGDisplayBounds(displayID)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  !ignoredWindowIDs.contains(number),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.intersects(display),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) >= 0.01
            else { return nil }
            return StackWindow(id: number, bounds: bounds, layer: (info[kCGWindowLayer as String] as? Int) ?? 0)
        }
    }
}
