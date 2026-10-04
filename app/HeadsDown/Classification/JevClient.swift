import Foundation

/// Reads `KEY=value` lines from the project's `.env`. The app runs from `app/build/...` inside the
/// repo, so it walks up from the app bundle to the first `.env`; `HEADSDOWN_ENV_FILE` overrides
/// the path. Values are never logged or shown.
enum EnvFile {
    static func url() -> URL? {
        if let override = ProcessInfo.processInfo.environment["HEADSDOWN_ENV_FILE"] {
            return URL(fileURLWithPath: override)
        }
        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// Environment variables win over the file.
    static func value(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
        guard let url = url(), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key {
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

/// Client for Jev, TypeSafe's hosted System One API (`POST /v1/systemone`, Bearer key).
///
/// One `classify` call is one HTTP request for one region, with the same question and state shape
/// as Laya. No retries here: the scheduler decides when (and whether) to ask again, so retries are
/// coordinated, counted, and dropped once the content is no longer on screen. Region text, app
/// name, window title, and the task leave the laptop, so this is only used after user consent.
final class JevClient: DistractionClassifier {
    /// The concrete version this project benchmarked (`bench/jev_compare.py`; `jev-latest` resolved
    /// to it on 2026-10-03). Pinned so an alias update can't silently change decisions or mix cached
    /// scores from different models. Override with TYPESAFE_DEFAULT_MODEL.
    static let pinnedModel = "jev-1.13.0"
    /// TypeSafe's published rate for Jev 1.13 input tokens (output tokens are free). Estimate only.
    static let usdPerMillionInput = 0.042
    /// Longest provider-requested wait we honor; longer values are treated as this.
    static let maxRetryAfter: TimeInterval = 300

    let model: String
    let baseURL: URL
    let questionVersion = DistractionQuestion.version
    let maxItemsPerRequest = 1
    let maxConcurrentRequests = 6
    let usdPerMillionInputTokens = JevClient.usdPerMillionInput
    private let session: URLSession

    /// Concrete model the provider reports serving requests. When the configured model is an
    /// alias (e.g. jev-latest), this is what identifies scores, so an alias update can't mix them.
    private(set) var servedModel: String?

    var providerID: String { "jev:\(servedModel ?? model)" }
    var displayName: String {
        servedModel.map { $0 == model ? "Jev (\(model))" : "Jev (\(model) → \($0))" } ?? "Jev (\(model))"
    }

    func adoptServedModel(_ served: String) -> Bool {
        let before = providerID
        servedModel = served
        return providerID != before
    }
    var endpointDescription: String { baseURL.host ?? baseURL.absoluteString }

    init() {
        model = EnvFile.value("TYPESAFE_DEFAULT_MODEL") ?? Self.pinnedModel
        baseURL = EnvFile.value("TYPESAFE_BASE_URL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.typesafe.ai")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// Read on each use so a key pasted into .env works without restarting.
    private var apiKey: String? { EnvFile.value("TYPESAFE_API_KEY") }

    func classify(task: String, inputs: [ClassifierInput]) async -> [ItemOutcome] {
        var outcomes: [ItemOutcome] = []
        for input in inputs { outcomes.append(await classifyOne(task: task, input: input)) }
        return outcomes
    }

    private func classifyOne(task: String, input: ClassifierInput) async -> ItemOutcome {
        guard let key = apiKey else { return ItemOutcome(error: .missingKey) }
        if Task.isCancelled { return ItemOutcome(error: .cancelled, cancelled: true) }
        let body: [String: Any] = [
            "model": model,
            "state": DistractionQuestion.state(task: task, region: input),
            "questions": DistractionQuestion.questions,
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return ItemOutcome(error: .malformed("could not encode request"))
        }
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { return ItemOutcome(error: .cancelled, cancelled: true) }
            return ItemOutcome(error: error.code == .timedOut ? .timeout : .unreachable)
        } catch {
            return ItemOutcome(error: .unreachable)
        }
        guard let http = response as? HTTPURLResponse else { return ItemOutcome(error: .malformed("no HTTP response")) }

        // Usage and model are read before anything else, so they're counted even if the answer is bad.
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var outcome = ItemOutcome(responded: true)
        outcome.model = root?["model"] as? String
        outcome.inputTokens = ((root?["usage"] as? [String: Any])?["input_tokens"] as? NSNumber)?.intValue
        switch http.statusCode {
        case 200:
            outcome.score = DistractionQuestion.score(fromAnswers: root?["answers"])
            if outcome.score == nil { outcome.error = .malformed("missing or invalid noul score") }
        case 401, 403:
            outcome.error = .unauthorized
        case 429, 529, 500...599:
            outcome.error = .overloaded(http.statusCode)
            if let header = http.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header),
               seconds.isFinite, seconds >= 0 {
                outcome.retryAfter = min(seconds, Self.maxRetryAfter)
            }
        default:
            outcome.error = .http(http.statusCode)
        }
        return outcome
    }

    func health() async -> ClassifierHealth {
        guard let key = apiKey else { return .unavailable("add TYPESAFE_API_KEY to .env") }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        do {
            // Versioned model IDs are accepted even when not listed, so a valid key is the signal here;
            // an unusable model shows up as an error on the first classification.
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable("no HTTP response") }
            if http.statusCode == 401 || http.statusCode == 403 { return .unavailable("API key rejected") }
            return http.statusCode == 200 ? .ready : .unavailable("HTTP \(http.statusCode)")
        } catch {
            return .unavailable("can't reach \(baseURL.host ?? "TypeSafe")")
        }
    }
}
