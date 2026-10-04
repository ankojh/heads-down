import Foundation

/// Per-session classifier usage. HTTP requests are counted separately from analysis passes.
struct ClassificationStats {
    var httpRequests = 0
    var responses = 0
    var retries = 0
    var failures = 0
    var cancelled = 0
    /// Valid scores received and cached.
    var decisions = 0
    /// Region appearances answered from the cache without asking the provider.
    var cacheHits = 0
    /// Inputs needed again while an identical request was already in flight (not resent).
    var inFlightShares = 0
    /// Queued inputs dropped before sending because they left the screen or changed.
    var obsoleteDropped = 0
    /// Results that arrived for an old task/provider/session; counted, never applied.
    var lateResults = 0
    /// Times the provider's served model changed mid-session (scores from that moment discarded).
    var modelChanges = 0
    var rounds = 0
    /// Provider-reported input tokens.
    var inputTokens = 0
    var lastModel: String?
    var pending = 0
    var inFlight = 0
}

/// Decides when classifier requests are sent.
///
/// - Latest-only: holds just the inputs the current regions still need, keyed by semantic cache key.
///   Inputs that leave the screen before dispatch are dropped unsent; no backlog of old screens.
/// - One registry entry per key: an input already in flight is never sent twice.
/// - At most one dispatch round per second (monotonic clock), starting up to the provider's free
///   request slots. No repeating timer: it only wakes when there is eligible work.
/// - Each request's results are delivered as soon as that request finishes, so successes survive
///   sibling failures, cancellation, and window switches.
/// - Retries use bounded exponential backoff with jitter, honor Retry-After, pause the whole provider
///   on overload, and are skipped once the input is no longer needed.
///
/// Cache-hit rendering never waits for this; the controller applies cached scores immediately.
@MainActor
final class ClassificationScheduler {
    static let roundInterval: Duration = .seconds(1)
    static let maxBackoff: TimeInterval = 60
    /// An input whose answer was invalid is retried once after this, then skipped for `invalidSkip`.
    static let invalidRetryDelay: TimeInterval = 30
    static let invalidSkip: TimeInterval = 600

    private struct Namespace: Equatable {
        let epoch: UInt64
        let task: String
        let revision: Int
    }

    private struct RetryState {
        var attempts = 0
        var invalidAnswers = 0
        var eligibleAt: ContinuousClock.Instant
    }

    private(set) var classifier: DistractionClassifier
    private(set) var stats = ClassificationStats()

    /// Newly scored (key, score) pairs for the current namespace.
    var onScores: (([(key: String, score: Double)]) -> Void)?
    /// A user-visible classifier problem, or nil when it's healthy again.
    var onProblem: ((String?) -> Void)?
    var onStatsChanged: (() -> Void)?
    /// Metadata-only record per finished request, for the diagnostics log.
    var onRequestLogged: (([String: Any]) -> Void)?
    /// The provider's identity changed (alias now serves another model): re-key and re-sync.
    var onIdentityChanged: (() -> Void)?
    /// Seconds until dispatch may proceed (0 = now), or nil to wait for the next `update`.
    var gateDelay: () -> TimeInterval? = { 0 }

    private let clock = ContinuousClock()
    private var epoch: UInt64 = 0
    private var namespace: Namespace?
    private var wanted: [String: ClassifierInput] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    private var requestsInFlight = 0
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var retry: [String: RetryState] = [:]
    /// Inputs skipped until the given time after repeated invalid answers.
    private var skipUntil: [String: ContinuousClock.Instant] = [:]
    /// Set when the provider rejects or lacks the API key: nothing is sent until `clearAuthBlock()`.
    private var authBlocked: String?
    private var providerBlockedUntil: ContinuousClock.Instant
    private var lastRoundAt: ContinuousClock.Instant?
    private var wakeTask: Task<Void, Never>?
    private var problem: String?

    init(classifier: DistractionClassifier) {
        self.classifier = classifier
        providerBlockedUntil = clock.now
    }

    // MARK: - Lifecycle

    /// Starts fresh counters for a new session.
    func resetStats() {
        stats = ClassificationStats()
        publishStats()
    }

    /// Stops all dispatch and retries immediately (pause/stop). In-flight requests are cancelled;
    /// anything they still return is counted but never applied.
    func stopAll() {
        epoch += 1
        namespace = nil
        wakeTask?.cancel()
        wakeTask = nil
        stats.obsoleteDropped += pendingKeys().count
        cancelRequests()
        wanted = [:]
        order = []
        retry = [:]
        publishStats()
    }

    /// Cancels in-flight requests and frees their slots now. Whatever they still return is counted
    /// in usage (it may be billed) but never applied.
    private func cancelRequests() {
        for request in requests.values { request.cancel() }
        requests = [:]
        inFlight = []
        requestsInFlight = 0
    }

    /// Lets dispatch resume after the API key was fixed (Check button, new session).
    func clearAuthBlock() {
        guard authBlocked != nil else { return }
        authBlocked = nil
        setProblem(nil)
        scheduleRound()
    }

    /// Switches provider. Results still arriving from the old one are ignored.
    func replace(classifier newClassifier: DistractionClassifier) {
        classifier = newClassifier
        epoch += 1
        namespace = nil
        cancelRequests()
        wanted = [:]
        order = []
        retry = [:]
        skipUntil = [:]
        authBlocked = nil
        providerBlockedUntil = clock.now
        setProblem(nil)
        publishStats()
    }

    /// Replaces the set of inputs the current screen needs (keys already exclude cache hits).
    func update(task: String, revision: Int, items: [(key: String, input: ClassifierInput)]) {
        if namespace?.task != task || namespace?.revision != revision {
            epoch += 1
            retry = [:]
            skipUntil = [:]
            namespace = Namespace(epoch: epoch, task: task, revision: revision)
        }
        let newKeys = Set(items.map(\.key))
        stats.obsoleteDropped += pendingKeys().filter { !newKeys.contains($0) }.count
        for key in newKeys where inFlight.contains(key) && wanted[key] == nil { stats.inFlightShares += 1 }
        wanted = [:]
        order = []
        let now = clock.now
        skipUntil = skipUntil.filter { $0.value > now }
        for item in items where skipUntil[item.key] == nil && wanted[item.key] == nil {
            wanted[item.key] = item.input
            order.append(item.key)
        }
        retry = retry.filter { newKeys.contains($0.key) }
        publishStats()
        scheduleRound()
    }

    func recordCacheHits(_ count: Int) {
        guard count > 0 else { return }
        stats.cacheHits += count
        publishStats()
    }

    // MARK: - Dispatch

    private func pendingKeys() -> [String] {
        order.filter { !inFlight.contains($0) }
    }

    private func scheduleRound() {
        guard wakeTask == nil, namespace != nil, authBlocked == nil else { return }
        let candidates = pendingKeys()
        guard !candidates.isEmpty, requestsInFlight < classifier.maxConcurrentRequests else { return }
        guard let gate = gateDelay() else { return }
        let now = clock.now
        let earliestRetry = candidates.map { retry[$0]?.eligibleAt ?? now }.min() ?? now
        var wakeAt = max(now, earliestRetry, providerBlockedUntil)
        if let lastRoundAt { wakeAt = max(wakeAt, lastRoundAt + Self.roundInterval) }
        wakeAt = max(wakeAt, now + .milliseconds(Int(gate * 1000)))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(until: wakeAt, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.wakeTask = nil
            self?.runRound()
        }
    }

    private func runRound() {
        guard let namespace, authBlocked == nil else { return }
        guard let gate = gateDelay() else { return }
        let now = clock.now
        if gate > 0 || now < providerBlockedUntil {
            scheduleRound()
            return
        }
        var slots = classifier.maxConcurrentRequests - requestsInFlight
        guard slots > 0 else { return }
        var eligible = pendingKeys().filter { (retry[$0]?.eligibleAt ?? now) <= now }[...]
        guard !eligible.isEmpty else {
            scheduleRound()
            return
        }
        lastRoundAt = now
        stats.rounds += 1
        while slots > 0, !eligible.isEmpty {
            let keys = Array(eligible.prefix(classifier.maxItemsPerRequest))
            eligible = eligible.dropFirst(keys.count)
            launch(keys, namespace: namespace)
            slots -= 1
        }
        publishStats()
        // Anything left waits for the next round, at least a second away.
        scheduleRound()
    }

    private func launch(_ keys: [String], namespace: Namespace) {
        let inputs = keys.compactMap { wanted[$0] }
        guard inputs.count == keys.count else { return }
        inFlight.formUnion(keys)
        requestsInFlight += 1
        stats.httpRequests += 1
        let isRetry = keys.contains { retry[$0] != nil }
        if isRetry { stats.retries += 1 }
        let classifier = self.classifier
        let id = UUID()
        let started = clock.now
        requests[id] = Task { [weak self] in
            let outcomes = await classifier.classify(task: namespace.task, inputs: inputs)
            self?.finish(
                id: id, keys: keys, outcomes: outcomes, namespace: namespace, started: started, isRetry: isRetry,
                classifier: classifier)
        }
    }

    // MARK: - Results

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func finish(
        id: UUID, keys: [String], outcomes: [ItemOutcome], namespace requestNamespace: Namespace,
        started: ContinuousClock.Instant, isRetry: Bool, classifier requestClassifier: DistractionClassifier
    ) {
        // Requests cancelled by stop/provider switch were already released; only count their usage.
        let registered = requests.removeValue(forKey: id) != nil
        if registered {
            requestsInFlight -= 1
            inFlight.subtract(keys)
        }
        let now = clock.now
        var current = registered && requestNamespace == namespace && requestClassifier === classifier
        if outcomes.contains(where: \.responded) { stats.responses += 1 }
        stats.inputTokens += outcomes.compactMap(\.inputTokens).reduce(0, +)
        if let model = outcomes.compactMap(\.model).last { stats.lastModel = model }

        // An alias now served by a different model: these scores belong to the new model, but were
        // keyed under the old identity. Discard them and re-key everything instead of mixing.
        if current, let served = outcomes.compactMap(\.model).last, classifier.adoptServedModel(served) {
            stats.modelChanges += 1
            epoch += 1
            namespace = nil
            wanted = [:]
            order = []
            retry = [:]
            current = false
            onIdentityChanged?()
        }

        var scored: [(key: String, score: Double)] = []
        var newProblem: String?
        for (key, outcome) in zip(keys, outcomes) {
            if outcome.cancelled {
                stats.cancelled += 1
                continue
            }
            guard current else {
                stats.lateResults += 1
                continue
            }
            if let score = outcome.score {
                // Resolved: it's in the cache now, so it must never be dispatched again.
                resolve(key)
                scored.append((key, score))
                stats.decisions += 1
                continue
            }
            stats.failures += 1
            var state = retry[key] ?? RetryState(eligibleAt: now)
            switch outcome.error {
            case .unauthorized, .missingKey:
                // Not a transient error: stop sending until the key is fixed.
                authBlocked = outcome.error?.errorDescription ?? "auth error"
                newProblem = "\(classifier.displayName): \(authBlocked ?? "") — fix .env, then press Check"
            case .some where outcome.retryable:
                state.attempts += 1
                let wait = outcome.retryAfter ?? Self.backoff(attempts: state.attempts)
                state.eligibleAt = now + .milliseconds(Int(wait * 1000))
                retry[key] = state
                // Pause the whole provider too, so parallel slots don't retry in a burst.
                providerBlockedUntil = max(providerBlockedUntil, state.eligibleAt)
                newProblem = newProblem ?? "\(classifier.displayName) unavailable "
                    + "(\(outcome.error?.errorDescription ?? "error")); retrying in \(Int(wait.rounded())) s"
            default:
                // Invalid answer or rejected input: one delayed retry, then skip it for a while.
                state.invalidAnswers += 1
                if state.invalidAnswers < 2 {
                    state.eligibleAt = now + .seconds(Self.invalidRetryDelay)
                    retry[key] = state
                } else {
                    skipUntil[key] = now + .seconds(Self.invalidSkip)
                    resolve(key)
                }
            }
        }
        if current {
            if !scored.isEmpty, newProblem == nil, authBlocked == nil {
                setProblem(nil)
            } else if let newProblem {
                setProblem(newProblem)
            }
            if !scored.isEmpty { onScores?(scored) }
        }
        let elapsed = started.duration(to: now)
        onRequestLogged?([
            "event": "classify_request", "provider": requestClassifier.providerID, "items": keys.count,
            "scored": outcomes.filter { $0.score != nil }.count,
            "tokens": outcomes.compactMap(\.inputTokens).reduce(0, +),
            "ms": Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
            "retry": isRetry, "late": !current, "model": outcomes.compactMap(\.model).last ?? NSNull(),
            "error": outcomes.compactMap(\.error).first?.category ?? NSNull(),
        ])
        publishStats()
        scheduleRound()
    }

    private func resolve(_ key: String) {
        retry[key] = nil
        wanted[key] = nil
        order.removeAll { $0 == key }
    }

    /// 2, 4, 8 … seconds (capped), with ±20% jitter so parallel failures don't retry in lockstep.
    private static func backoff(attempts: Int) -> TimeInterval {
        min(maxBackoff, pow(2, Double(attempts))) * Double.random(in: 0.8...1.2)
    }

    private func setProblem(_ text: String?) {
        guard text != problem else { return }
        problem = text
        onProblem?(text)
    }

    private func publishStats() {
        stats.pending = pendingKeys().count
        stats.inFlight = inFlight.count
        onStatsChanged?()
    }
}
