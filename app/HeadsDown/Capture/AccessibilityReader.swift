import ApplicationServices
import CoreGraphics
import Foundation

struct AXReadResult {
    var texts: [TextObservation] = []
    var containers: [AXContainer] = []
    var nodesVisited = 0
    var limitHit: String?
    var windowMatched = false
    var status: String
}

/// Bounded read of one window's accessibility tree: text with bounds, plus container frames that
/// can serve as region boundaries. Runs off the main thread; every call into the target app has a
/// short messaging timeout so a slow app can't stall the controls.
enum AccessibilityReader {
    static let maxNodes = 4000
    static let maxDepth = 64
    static let timeBudget: TimeInterval = 0.6
    static let messagingTimeout: Float = 0.25
    static let maxTextLength = 1000

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute,
    ] as CFArray

    private static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let labelledLeafRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXHeading", "AXCell", "AXMenuItem",
    ]
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXList", "AXRow", "AXCell", "AXTable", "AXOutline", "AXScrollArea",
        "AXSplitGroup", "AXTabGroup", "AXWebArea", "AXLayoutArea", "AXLayoutItem", "AXBrowser",
        "AXGrid", "AXLink", "AXSheet",
    ]

    private struct Node {
        let element: AXUIElement
        let depth: Int
    }

    static func read(target: TargetWindow, generation: UInt64) -> AXReadResult {
        guard AXIsProcessTrusted() else { return AXReadResult(status: "Accessibility not granted") }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            return AXReadResult(status: "App exposes no accessible windows")
        }
        let window = windows.first { candidate in
            guard let frame = frame(of: candidate) else { return false }
            return abs(frame.minX - target.bounds.minX) <= 4 && abs(frame.minY - target.bounds.minY) <= 4
                && abs(frame.width - target.bounds.width) <= 4 && abs(frame.height - target.bounds.height) <= 4
        }
        guard let window else {
            return AXReadResult(status: "Couldn't match an accessible window to the captured one")
        }

        var result = AXReadResult(windowMatched: true, status: "Read")
        let visible = target.visibleRect
        let deadline = Date().addingTimeInterval(timeBudget)
        var queue: [Node] = [Node(element: window, depth: 0)]
        var head = 0

        while head < queue.count {
            if result.nodesVisited >= maxNodes { result.limitHit = "node limit (\(maxNodes))"; break }
            if Date() > deadline { result.limitHit = "time limit (\(Int(timeBudget * 1000)) ms)"; break }
            let node = queue[head]
            head += 1
            result.nodesVisited += 1

            guard let values = copyMultiple(node.element) else { continue }
            let role = values[0] as? String ?? ""
            let subrole = values[1] as? String
            let rect = rectFrom(position: values[2], size: values[3])

            // Prune subtrees entirely outside the visible area; keep frameless nodes.
            if let rect, rect.area > 0, !rect.intersects(visible) { continue }

            let children = children(of: node.element, role: role, fallback: values[7])
            collect(
                role: role, subrole: subrole, rect: rect, values: values, hasChildren: !children.isEmpty,
                depth: node.depth, target: target, generation: generation, into: &result)

            if node.depth < maxDepth {
                queue.append(contentsOf: children.map { Node(element: $0, depth: node.depth + 1) })
            } else {
                result.limitHit = "depth limit (\(maxDepth))"
            }
        }
        if let limit = result.limitHit { result.status = "Partial read: hit \(limit)" }
        return result
    }

    private static func collect(
        role: String, subrole: String?, rect: CGRect?, values: [AnyObject?], hasChildren: Bool,
        depth: Int, target: TargetWindow, generation: UInt64, into result: inout AXReadResult
    ) {
        guard let rect, rect.area > 0 else { return }
        let visible = target.visibleRect
        let clipped = rect.intersection(visible)
        guard !clipped.isNull, clipped.area > 0 else { return }

        var text: String?
        if role == "AXStaticText" {
            text = nonEmpty(values[4]) ?? nonEmpty(values[5]) ?? nonEmpty(values[6])
        } else if textInputRoles.contains(role) {
            let value = nonEmpty(values[4])
            // Big editors/documents become containers; OCR supplies their visible lines.
            if let value, rect.height <= 0.3 * visible.height, value.count <= 600 {
                text = value
            } else {
                result.containers.append(AXContainer(rect: clipped, role: role, subrole: subrole, depth: depth))
            }
        } else if labelledLeafRoles.contains(role), !hasChildren {
            text = nonEmpty(values[5]) ?? nonEmpty(values[4]) ?? nonEmpty(values[6])
        }

        if let text, clipped.area >= 0.3 * rect.area {
            result.texts.append(TextObservation(
                text: String(text.prefix(maxTextLength)), rect: clipped, source: .accessibility,
                ocrConfidence: nil, axRole: role, lineHeight: clipped.height,
                windowID: target.windowID, generation: generation))
        }
        if containerRoles.contains(role), hasChildren {
            result.containers.append(AXContainer(rect: clipped, role: role, subrole: subrole, depth: depth))
        }
    }

    private static func children(of element: AXUIElement, role: String, fallback: AnyObject?) -> [AXUIElement] {
        // Large tables and lists: prefer only the visible rows/children.
        if role == "AXTable" || role == "AXOutline",
           let rows = copy(element, kAXVisibleRowsAttribute) as? [AXUIElement] {
            return rows
        }
        if role == "AXList" || role == "AXBrowser",
           let visibleChildren = copy(element, kAXVisibleChildrenAttribute) as? [AXUIElement] {
            return visibleChildren
        }
        return (fallback as? [AXUIElement]) ?? []
    }

    // MARK: - AX helpers

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    /// Returns values aligned with `attributes`; missing attributes become nil.
    private static func copyMultiple(_ element: AXUIElement) -> [AnyObject?]? {
        var raw: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard err == .success, let array = raw as [AnyObject]?, array.count == CFArrayGetCount(attributes)
        else { return nil }
        return array.map { isAXError($0) ? nil : $0 }
    }

    private static func isAXError(_ value: AnyObject) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        // swiftlint:disable:next force_cast
        return AXValueGetType(value as! AXValue) == .axError
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        rectFrom(position: copy(element, kAXPositionAttribute), size: copy(element, kAXSizeAttribute))
    }

    private static func rectFrom(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: origin, size: extent)
    }

    private static func nonEmpty(_ value: AnyObject?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
