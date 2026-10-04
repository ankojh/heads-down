import Foundation

/// What a provider sees for one region. Text only; never screenshots.
struct ClassifierInput {
    let app: String
    let title: String
    let text: String
}

/// What one provider request reported for one input. Captured per HTTP request, so successful
/// results are kept even when sibling requests fail or are cancelled.
struct ItemOutcome {
    /// Validated P(distracting) in [0, 1], or nil. nil means unknown, never 0 or 1.
    var score: Double?
    var error: ClassifierError?
    /// Provider-requested wait before retrying (Retry-After), if any.
    var retryAfter: TimeInterval?
    var cancelled = false
    /// True if an HTTP response came back (the request reached the provider and may be billed).
    var responded = false
    /// Concrete model the provider reports having used.
    var model: String?
    /// Provider-reported input tokens for the request this item was part of.
    var inputTokens: Int?

    /// Worth asking again later (network trouble, overload); otherwise the input is unscorable.
    var retryable: Bool {
        switch error {
        case .timeout, .unreachable, .overloaded: return true
        default: return false
        }
    }
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
    case missingKey
    case unauthorized
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreachable: return "classifier not reachable"
        case .timeout: return "classifier timed out"
        case .overloaded(let code): return "classifier busy or rate-limited (HTTP \(code))"
        case .http(let code): return "classifier rejected the request (HTTP \(code))"
        case .malformed(let detail): return "unexpected classifier response: \(detail)"
        case .missingKey: return "no TYPESAFE_API_KEY found in .env"
        case .unauthorized: return "API key rejected (HTTP 401)"
        case .cancelled: return "request cancelled"
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
        case .missingKey: return "missing_key"
        case .unauthorized: return "unauthorized"
        case .cancelled: return "cancelled"
        }
    }
}

/// Which classifier the app uses. Jev is hosted: region text, app names, window titles, and the
/// task leave the laptop, so it's only used after the user has consented once.
enum ClassifierProvider: String, CaseIterable, Identifiable {
    case jev, laya
    var id: String { rawValue }

    var label: String {
        switch self {
        case .jev: return "Jev (cloud)"
        case .laya: return "Laya (local)"
        }
    }

    var sendsTextOffDevice: Bool { self == .jev }
}

/// Provider boundary. Geometry, tracking, and overlays never see provider-specific JSON.
/// One `classify` call is one provider request (no internal retries); the scheduler owns retries,
/// backoff, concurrency, and dispatch timing.
protocol DistractionClassifier: AnyObject {
    /// Part of the score-cache key, so scores from different providers/models never mix.
    var providerID: String { get }
    var questionVersion: String { get }
    var displayName: String { get }
    var endpointDescription: String { get }
    /// Inputs per request: 1 for Jev (no documented batch endpoint), more for Laya's local batch.
    var maxItemsPerRequest: Int { get }
    var maxConcurrentRequests: Int { get }
    /// For the Inspector's cost estimate; 0 for local providers.
    var usdPerMillionInputTokens: Double { get }
    /// Returns one outcome per input, in order. Never throws; failures are per-item outcomes.
    func classify(task: String, inputs: [ClassifierInput]) async -> [ItemOutcome]
    func health() async -> ClassifierHealth
    /// Records the concrete model a response says served it. Returns true if that changes
    /// `providerID` (an alias moved to a new model), so cached scores must not be shared.
    func adoptServedModel(_ model: String) -> Bool
}

extension DistractionClassifier {
    func adoptServedModel(_ model: String) -> Bool { false }
}

/// The question both providers get, copied verbatim from `bench/cases.py`. Model accuracy is very
/// sensitive to wording, so change it only together with the benchmark.
enum DistractionQuestion {
    static let version = "distracting-noul-v1"
    static let questions: [String: Any] = [
        "distracting": [
            "type": "noul",
            "instructions": "Would looking at this screen region pull the user away from their current task?",
            "criteria": [
                "false": "Relevant to or supports the current task",
                "true": "Unrelated to the current task and likely to distract",
            ],
        ],
    ]

    static func state(task: String, region: ClassifierInput) -> [String: Any] {
        ["current_task": task, "screen_region": ["app": region.app, "title": region.title, "text": region.text]]
    }

    /// Validated P(distracting) from one result's `answers`, or nil.
    static func score(fromAnswers answers: Any?) -> Double? {
        guard let answers = answers as? [String: Any],
              let distracting = answers["distracting"] as? [String: Any],
              let number = distracting["noul"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite && (0...1).contains(value) ? value : nil
    }
}
