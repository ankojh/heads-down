import Foundation

/// Client for a locally running `laya-serve` (loopback only).
///
/// Request shape matches `bench/load.py`; the question is `DistractionQuestion` (verbatim from
/// `bench/cases.py`). Response envelope (checked against a real
/// 0.3.26 batch response and `laya/serve.py`): `{"results": [...], "total_usage": {...}}`, one
/// result per state in request order, score at `results[i].answers.distracting.noul`.
final class LayaClient: DistractionClassifier {
    let providerID = "laya-local"
    let questionVersion = DistractionQuestion.version
    let displayName = "Laya (local)"
    let baseURL: URL
    /// The server collates a batch into one forward pass; keep requests modest.
    let maxItemsPerRequest = 16
    /// The server runs one inference at a time; concurrency would only queue.
    let maxConcurrentRequests = 1
    let usdPerMillionInputTokens = 0.0

    private let session: URLSession

    var endpointDescription: String { baseURL.absoluteString }

    init(baseURL: URL = URL(string: "http://127.0.0.1:8077")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// One local batch request (up to `maxItemsPerRequest` inputs); per-item outcomes once it returns.
    func classify(task: String, inputs: [ClassifierInput]) async -> [ItemOutcome] {
        func all(_ outcome: ItemOutcome) -> [ItemOutcome] { Array(repeating: outcome, count: inputs.count) }
        if Task.isCancelled { return all(ItemOutcome(error: .cancelled, cancelled: true)) }
        let states = inputs.map { DistractionQuestion.state(task: task, region: $0) }
        let body: [String: Any] = ["model": "laya", "states": states, "questions": DistractionQuestion.questions]
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return all(ItemOutcome(error: .malformed("could not encode request")))
        }
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { return all(ItemOutcome(error: .cancelled, cancelled: true)) }
            return all(ItemOutcome(error: error.code == .timedOut ? .timeout : .unreachable))
        } catch {
            return all(ItemOutcome(error: .unreachable))
        }
        guard let http = response as? HTTPURLResponse else { return all(ItemOutcome(error: .malformed("no HTTP response"))) }
        switch http.statusCode {
        case 200: break
        case 429, 503: return all(ItemOutcome(error: .overloaded(http.statusCode), responded: true))
        default: return all(ItemOutcome(error: .http(http.statusCode), responded: true))
        }
        do {
            return try Self.decode(data, expectedCount: inputs.count)
        } catch {
            return all(ItemOutcome(error: (error as? ClassifierError) ?? .malformed("bad response"), responded: true))
        }
    }

    /// Strict decoding: the result count must match, and each score must be a finite number in [0, 1].
    /// A bad item becomes an unscorable outcome rather than failing the whole batch.
    static func decode(_ data: Data, expectedCount: Int) throws -> [ItemOutcome] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [Any]
        else { throw ClassifierError.malformed("missing results array") }
        guard results.count == expectedCount else {
            throw ClassifierError.malformed("expected \(expectedCount) results, got \(results.count)")
        }
        return results.map { item in
            let result = item as? [String: Any]
            var outcome = ItemOutcome(responded: true)
            outcome.score = DistractionQuestion.score(fromAnswers: result?["answers"])
            outcome.model = result?["model"] as? String
            outcome.inputTokens = ((result?["usage"] as? [String: Any])?["input_tokens"] as? NSNumber)?.intValue
            if outcome.score == nil { outcome.error = .malformed("missing or invalid noul score") }
            return outcome
        }
    }

    func health() async -> ClassifierHealth {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable("no HTTP response") }
            guard http.statusCode == 200 else { return .loading("HTTP \(http.statusCode)") }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let loaded = root?["loaded"] as? [String] ?? []
            return loaded.isEmpty ? .loading("model not loaded yet") : .ready
        } catch {
            return .unavailable("nothing answering at \(baseURL.host ?? "?"):\(baseURL.port ?? 0)")
        }
    }
}
