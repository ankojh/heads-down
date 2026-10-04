import CoreGraphics
import Foundation

// Shared entities. All rectangles are in the canonical Quartz global space documented in
// Capture/Geometry.swift unless a name says otherwise.

enum CoverMode: String, CaseIterable, Identifiable {
    case observe, dim, blur
    var id: String { rawValue }
    var label: String {
        switch self {
        case .observe: return "Observe"
        case .dim: return "Dim"
        case .blur: return "Blur"
        }
    }
    var explanation: String {
        switch self {
        case .observe: return "Nothing is hidden. Boxes and scores only."
        case .dim: return "Regions scoring ≥ 0.50 are darkened (not blurred)."
        case .blur: return "≥ 0.80 blurred from a snapshot, 0.50–0.80 dimmed."
        }
    }
}

enum RunState: Equatable {
    case stopped, requestingPermissions, observing, processing, paused, degraded

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .requestingPermissions: return "Requesting permissions"
        case .observing: return "Observing"
        case .processing: return "Processing"
        case .paused: return "Paused"
        case .degraded: return "Degraded"
        }
    }
}

enum CoverAction: String {
    case leave, dim, blur
}

enum TextSource: String {
    case accessibility = "AX"
    case ocr = "OCR"
}

struct TextObservation {
    var text: String
    var rect: CGRect
    var source: TextSource
    /// Vision recognition confidence. Not a distraction probability.
    var ocrConfidence: Float?
    var axRole: String?
    /// Estimated single-line height, used for grouping. For multi-line AX text this is
    /// taken from overlapping OCR lines rather than the element's full height.
    var lineHeight: CGFloat
    var windowID: CGWindowID
    var generation: UInt64
}

struct AXContainer {
    var rect: CGRect
    var role: String
    var subrole: String?
    var depth: Int
}

struct Occluder: Equatable {
    var rect: CGRect
    var owner: String
    var layer: Int
}

struct TargetWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let title: String
    /// Full window bounds.
    let bounds: CGRect
    /// The part of the window on the selected display. This is what gets captured.
    let visibleRect: CGRect
    let displayID: CGDirectDisplayID
    /// Higher windows overlapping this one, clipped to `visibleRect`.
    let occluders: [Occluder]
    /// Overlapping windows at layer >= 1000 that were assumed transparent and not treated as occluders.
    let ignoredOverlays: [Occluder]

    func sameGeometry(as other: TargetWindow) -> Bool {
        windowID == other.windowID && bounds == other.bounds && displayID == other.displayID
            && occluders == other.occluders
    }
}

struct ScreenSnapshot {
    let cycleID: UInt64
    let capturedAt: Date
    let geometry: CaptureGeometry
    let image: CGImage
}

struct ScreenRegion: Identifiable {
    /// Transient tracking ID: content fingerprint plus an occurrence index.
    let id: String
    var number: Int
    var rect: CGRect
    var text: String
    var appName: String
    var windowTitle: String
    var sources: Set<TextSource>
    var observationCount: Int
    var reason: String
    /// Hash of normalized region text. Used for tracking and reveal overrides.
    var fingerprint: String
    /// Hash of everything the classifier sees (app, title, text). Used for score caching.
    var classifierFingerprint: String
    var geometryUncertain: Bool
    var windowID: CGWindowID

    var sourceLabel: String {
        sources.map(\.rawValue).sorted().joined(separator: "+")
    }
}

struct RegionDecision {
    let regionID: String
    let fingerprint: String
    let taskRevision: Int
    let cycleID: UInt64
    let providerID: String
    let questionVersion: String
    /// Validated P(distracting), or nil when no valid score exists.
    let pDistracting: Double?
    let tier: CoverAction
    let action: CoverAction
    let overridden: Bool
    let policyNote: String
    let decidedAt: Date
}

struct Coverage {
    var appName: String?
    var windowTitle: String?
    var windowID: CGWindowID?
    var displayName: String
    var bounds: CGRect?
    var readMode: String = "—"
    var axStatus: String = "—"
    var skippedAreas: [String] = []
    var notes: [String] = []
    var skipReason: String?
}

struct CycleTimings {
    var cycleID: UInt64 = 0
    var queueMs: Double?
    var captureMs: Double = 0
    var axMs: Double = 0
    var ocrMs: Double = 0
    var groupMs: Double = 0
    var classifyMs: Double?
    var blurMs: Double?
    var totalMs: Double = 0
    var captureToOverlayMs: Double = 0
    var changeToOverlayMs: Double?
    var regionCount = 0
    var classifiedCount = 0
    var cachedCount = 0
    var axNodes = 0
    var axTexts = 0
    var ocrLines = 0

    var summary: String {
        var parts = [
            "capture \(Int(captureMs))",
            "AX \(Int(axMs))",
            "OCR \(Int(ocrMs))",
            "group \(Int(groupMs))",
        ]
        if let classifyMs { parts.append("classify \(Int(classifyMs))") }
        if let blurMs { parts.append("blur \(Int(blurMs))") }
        parts.append("cycle \(Int(totalMs)) ms")
        var text = parts.joined(separator: " · ")
        if let changeToOverlayMs { text += " · change→overlay \(Int(changeToOverlayMs)) ms" }
        return text
    }
}

func elapsedMs(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func overlapFraction(of other: CGRect) -> CGFloat {
        let shared = intersection(other)
        return other.area > 0 ? shared.area / other.area : 0
    }

    var shortDescription: String {
        "x \(Int(minX)), y \(Int(minY)), \(Int(width))×\(Int(height)) pt"
    }
}
