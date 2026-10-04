import Foundation

/// What a provider sees for one region. Text only; never screenshots.
struct ClassifierInput {
    let app: String
    let title: String
    let text: String
}

struct RegionScore {
    /// Validated P(distracting) in [0, 1], or nil when the provider's answer for this item was
    /// missing or invalid. nil means unknown, never 0 or 1.
    let pDistracting: Double?
}

enum ClassifierHealth: Equatable {
    case ready
    case loading(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .loading(let detail): return "Loading: \(detail)"
        case .unavailable(let detail): return "Unavailable: \(detail)"
        }
    }
}

enum ClassifierError: LocalizedError {
    case unreachable
    case timeout
    case overloaded(Int)
    case http(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "classifier not reachable"
        case .timeout: return "classifier timed out"
        case .overloaded(let code): return "classifier busy or loading (HTTP \(code))"
        case .http(let code): return "classifier rejected the request (HTTP \(code))"
        case .malformed(let detail): return "unexpected classifier response: \(detail)"
        }
    }

    /// Short category for local logs.
    var category: String {
        switch self {
        case .unreachable: return "unreachable"
        case .timeout: return "timeout"
        case .overloaded: return "overloaded"
        case .http: return "http"
        case .malformed: return "malformed"
        }
    }
}

/// Provider boundary. Geometry, tracking, and overlays never see provider-specific JSON.
/// A hosted provider (e.g. Jev) would get its own adapter plus explicit user consent, since region
/// text would then leave the laptop.
protocol DistractionClassifier: AnyObject {
    var providerID: String { get }
    var questionVersion: String { get }
    var endpointDescription: String { get }
    func classify(task: String, regions: [ClassifierInput]) async throws -> [RegionScore]
    func health() async -> ClassifierHealth
}
