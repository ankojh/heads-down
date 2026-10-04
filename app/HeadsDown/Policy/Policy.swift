import Foundation

/// Threshold policy from the benchmark plan. The score is a distraction probability from the
/// model, not a guarantee; segmentation quality is judged separately (`geometryUncertain`).
enum Policy {
    static let blurAt = 0.8
    static let dimAt = 0.5

    static func tier(for score: Double?) -> CoverAction {
        guard let score else { return .leave }
        if score >= blurAt { return .blur }
        if score >= dimAt { return .dim }
        return .leave
    }

    /// What actually happens on screen, with a short policy note (not a model rationale).
    static func applied(
        score: Double?, mode: CoverMode, geometryUncertain: Bool, revealed: Bool
    ) -> (action: CoverAction, note: String) {
        let tier = tier(for: score)
        guard let score else { return (.leave, "No valid score yet — left uncovered") }
        if tier == .leave { return (.leave, String(format: "%.2f < 0.50 — left alone", score)) }
        if revealed { return (.leave, "Revealed by you — left uncovered") }
        if geometryUncertain { return (.leave, "Overlaps another window — left uncovered") }
        switch mode {
        case .observe:
            return (.leave, "Observe mode — would \(tier.rawValue)")
        case .dim:
            return (.dim, String(format: "%.2f ≥ 0.50 — dimmed (dim mode)", score))
        case .blur:
            return tier == .blur
                ? (.blur, String(format: "%.2f ≥ 0.80 — blurred", score))
                : (.dim, String(format: "0.50 ≤ %.2f < 0.80 — dimmed", score))
        }
    }
}

/// Temporary reveals, scoped to one task revision and one region's content. Cleared on task
/// change and session end; they never become a site or app allowlist.
final class RevealOverrides {
    static let duration: TimeInterval = 10 * 60
    private var expiries: [String: Date] = [:]

    private func key(_ revision: Int, _ fingerprint: String) -> String { "\(revision)|\(fingerprint)" }

    func reveal(revision: Int, fingerprint: String) {
        expiries[key(revision, fingerprint)] = Date().addingTimeInterval(Self.duration)
    }

    func unreveal(revision: Int, fingerprint: String) {
        expiries[key(revision, fingerprint)] = nil
    }

    func isRevealed(revision: Int, fingerprint: String) -> Bool {
        guard let expiry = expiries[key(revision, fingerprint)] else { return false }
        if expiry < Date() {
            expiries[key(revision, fingerprint)] = nil
            return false
        }
        return true
    }

    func expiry(revision: Int, fingerprint: String) -> Date? {
        isRevealed(revision: revision, fingerprint: fingerprint) ? expiries[key(revision, fingerprint)] : nil
    }

    func clear() {
        expiries.removeAll()
    }
}

/// Bounded score cache keyed by task revision, provider, question version, and classifier input.
struct ScoreCache {
    let limit: Int
    private var values: [String: Double] = [:]
    private var order: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    static func key(revision: Int, provider: String, question: String, input: String) -> String {
        "\(revision)|\(provider)|\(question)|\(input)"
    }

    subscript(key: String) -> Double? { values[key] }

    mutating func set(_ key: String, _ value: Double) {
        if values.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > limit { values[order.removeFirst()] = nil }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }
}
