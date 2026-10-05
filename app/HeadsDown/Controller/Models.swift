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
        case .observe:
            return "Debug only: nothing is hidden. Boxes and scores, no focus protection."
        case .dim:
            return "Darkens what the hiding level marks as distracting."
        case .blur:
            return "Blurs what the hiding level marks as distracting."
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

/// Semantic verdict for one region under the strict policy. Rendering depends on the mode.
enum Verdict: String {
    /// Valid low distraction score: allowed to stay visible.
    case keep
    /// Valid score at or above the keep cutoff.
    case cover
    /// No valid score (pending, failed, or malformed). Covered in strict mode.
    case unknown
}

/// Why the controller decided screen analysis is needed.
enum DirtyReason: String {
    case newTarget = "new_target"
    case layout
    case localChange = "local_change"
    case motion
    case scroll
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

    /// Popups and tooltips change clipping, not the underlying window's coordinate space.
    func sameFrame(as other: TargetWindow) -> Bool {
        windowID == other.windowID && bounds == other.bounds && visibleRect == other.visibleRect
            && displayID == other.displayID
    }

    /// Captures/reads must also agree on what was occluded when their pixels were captured.
    func sameGeometry(as other: TargetWindow) -> Bool {
        sameFrame(as: other) && occluders == other.occluders
    }
}

/// A window that was analyzed while frontmost and is still visible behind other windows. Its
/// cover keeps being drawn from what was read then (policy re-applied to current scores) until
/// the window moves, disappears, or becomes frontmost and is re-read.
struct RetainedWindow {
    let windowID: CGWindowID
    let bounds: CGRect
    let visibleRect: CGRect
    let regions: [ScreenRegion]
    let chrome: ContentEnvelope.Chrome?
    let controls: [CGRect]
    /// Last blurred cover image (not refreshed while the window is in the background).
    let coverImage: CGImage?
    var occluders: [CGRect] = []
    /// Position in the window stack (0 = frontmost); used to draw back to front.
    var stackIndex = 0
    let retainedAt: Date
}

struct ScreenSnapshot {
    let cycleID: UInt64
    let capturedAt: Date
    let geometry: CaptureGeometry
    let image: CGImage
}

struct ScreenRegion: Identifiable {
    /// Transient tracking ID: content fingerprint plus an occurrence index.
    var id: String
    var number: Int
    var rect: CGRect
    /// Canonical text exactly as submitted to the classifier (already truncated).
    var text: String
    var appName: String
    /// Canonical window title exactly as submitted to the classifier.
    var windowTitle: String
    var sources: Set<TextSource>
    var observationCount: Int
    var reason: String
    /// Hash of normalized region text. Used for tracking and reveal overrides.
    var fingerprint: String
    /// Hash of the exact canonical classifier payload. Used for score caching.
    var classifierFingerprint: String
    var geometryUncertain: Bool
    var windowID: CGWindowID
    /// A fragment cut by a pane edge that kept the identity (text, fingerprints) of the whole
    /// region it was scrolled from. See `SessionController.inheritEdgeIdentity`.
    var identityKept = false

    var sourceLabel: String {
        sources.map(\.rawValue).sorted().joined(separator: "+")
    }
}

struct RegionDecision {
    let regionID: String
    let fingerprint: String
    let taskRevision: Int
    let providerID: String
    let questionVersion: String
    let policyVersion: String
    /// Validated P(distracting), or nil when no valid score exists.
    let pDistracting: Double?
    let verdict: Verdict
    /// True when policy allows the region to stay visible (keep verdict or a user reveal).
    let visibleIntent: Bool
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
    var chromeNote: String = "—"
    var skippedAreas: [String] = []
    var notes: [String] = []
    var skipReason: String?
}

struct CycleTimings {
    var cycleID: UInt64 = 0
    var trigger = ""
    var queueMs: Double?
    var captureMs: Double = 0
    var axMs: Double = 0
    var ocrMs: Double = 0
    var groupMs: Double = 0
    var totalMs: Double = 0
    var changeToOverlayMs: Double?
    var ocrScope = "full"
    var ocrBandFraction: Double = 1
    var ocrFresh = 0
    var ocrReused = 0
    var regionCount = 0
    var cacheHits = 0
    var missesChanged = 0
    var missesNew = 0
    var axNodes = 0
    var axTexts = 0

    var summary: String {
        var parts = [
            "capture \(Int(captureMs))",
            "AX \(Int(axMs))",
            "OCR \(Int(ocrMs)) (\(ocrScope))",
            "group \(Int(groupMs))",
        ]
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
