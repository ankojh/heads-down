import Foundation

/// Client for a locally running `laya-serve` (loopback only).
///
/// Request shape matches `bench/load.py`; the question is copied verbatim from `bench/cases.py`
/// because Laya's accuracy is very sensitive to wording. Response envelope (checked against a real
/// 0.3.26 batch response and `laya/serve.py`): `{"results": [...], "total_usage": {...}}`, one
/// result per state in request order, score at `results[i].answers.distracting.noul`.
final class LayaClient: DistractionClassifier {
    let providerID = "laya-local"
    let questionVersion = "distracting-noul-v1"
    let baseURL: URL
    /// The server collates a batch into one forward pass; keep requests modest.
    static let maxBatch = 16

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

    private static let questions: [String: Any] = [
        "distracting": [
            "type": "noul",
            "instructions": "Would looking at this screen region pull the user away from their current task?",
            "criteria": [
                "false": "Relevant to or supports the current task",
                "true": "Unrelated to the current task and likely to distract",
            ],
        ],
    ]

    func classify(task: String, regions: [ClassifierInput]) async throws -> [RegionScore] {
        var scores: [RegionScore] = []
        var start = 0
        while start < regions.count {
            let chunk = Array(regions[start..<min(regions.count, start + Self.maxBatch)])
            scores += try await classifyChunk(task: task, regions: chunk)
            start += Self.maxBatch
        }
        return scores
    }

    private func classifyChunk(task: String, regions: [ClassifierInput]) async throws -> [RegionScore] {
        let states: [[String: Any]] = regions.map { region in
            [
                "current_task": task,
                "screen_region": ["app": region.app, "title": region.title, "text": region.text],
            ]
        }
        let body: [String: Any] = ["model": "laya", "states": states, "questions": Self.questions]
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? ClassifierError.timeout : ClassifierError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ClassifierError.malformed("no HTTP response") }
        switch http.statusCode {
        case 200: break
        case 429, 503: throw ClassifierError.overloaded(http.statusCode)
        default: throw ClassifierError.http(http.statusCode)
        }
        return try Self.decode(data, expectedCount: regions.count)
    }

    /// Strict decoding: the result count must match, and each score must be a finite number in [0, 1].
    /// A bad item becomes nil (unknown) rather than failing the whole batch.
    static func decode(_ data: Data, expectedCount: Int) throws -> [RegionScore] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [Any]
        else { throw ClassifierError.malformed("missing results array") }
        guard results.count == expectedCount else {
            throw ClassifierError.malformed("expected \(expectedCount) results, got \(results.count)")
        }
        return results.map { item in
            guard let result = item as? [String: Any],
                  let answers = result["answers"] as? [String: Any],
                  let distracting = answers["distracting"] as? [String: Any],
                  let number = distracting["noul"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return RegionScore(pDistracting: nil) }
            let value = number.doubleValue
            return RegionScore(pDistracting: value.isFinite && (0...1).contains(value) ? value : nil)
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
