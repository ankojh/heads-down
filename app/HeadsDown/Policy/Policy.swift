import Foundation

/// How much Heads Down hides. Cutoffs are uncalibrated starting points chosen from one session's
/// score distribution (median 0.57; only 4% of regions scored below 0.20), not measured optimums.
enum Strictness: String, CaseIterable, Identifiable {
    case relaxed, balanced, strict
    var id: String { rawValue }

    var label: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .balanced: return "Balanced"
        case .strict: return "Strict"
        }
    }

    /// Regions scoring at or above this are distracting.
    var coverAt: Double {
        switch self {
        case .relaxed: return 0.65
        case .balanced, .strict: return 0.5
        }
    }

    /// Strict covers the whole window except related regions; the others cover distracting regions only.
    var coversWholeWindow: Bool { self == .strict }

    var explanation: String {
        switch self {
        case .relaxed: return String(format: "Only regions scoring ≥ %.2f are hidden.", coverAt)
        case .balanced: return String(format: "Regions scoring ≥ %.2f are hidden.", coverAt)
        case .strict:
            return String(format: "Everything is hidden except regions scoring < %.2f.", coverAt)
        }
    }
}

/// Turns a distraction score into a verdict for the chosen strictness. The model question is
/// unchanged; only how its score is used changes. Controls and window chrome are never covered,
/// regardless of verdict (see the renderer).
enum Policy {
    static func version(_ strictness: Strictness) -> String {
        String(format: "%@-%.2f", strictness.rawValue, strictness.coverAt)
    }

    /// Returns the verdict, whether the region may stay visible, and a short policy note.
    static func decide(
        score: Double?, strictness: Strictness, revealed: Bool, revealExpiry: Date?
    ) -> (Verdict, Bool, String) {
        let cutoff = strictness.coverAt
        let verdict: Verdict
        let note: String
        if let score {
            if score < cutoff {
                verdict = .keep
                note = String(format: "%.2f < %.2f — left visible", score, cutoff)
            } else {
                verdict = .cover
                note = String(format: "%.2f ≥ %.2f — hidden", score, cutoff)
            }
        } else {
            verdict = .unknown
            note = strictness.coversWholeWindow
                ? "No valid score yet — hidden (Strict)" : "No valid score yet — left visible"
        }
        if revealed {
            let until = revealExpiry.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return (verdict, true, "Revealed by you\(until)")
        }
        let visible = strictness.coversWholeWindow ? verdict == .keep : verdict != .cover
        return (verdict, visible, note)
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

    func expiry(revision: Int, fingerprint: String) -> Date? {
        guard let expiry = expiries[key(revision, fingerprint)], expiry > Date() else { return nil }
        return expiry
    }

    /// Drops expired reveals. Returns true if any expired, so policy can be re-applied even on a
    /// completely static screen.
    func expireDue() -> Bool {
        let now = Date()
        let before = expiries.count
        expiries = expiries.filter { $0.value > now }
        return expiries.count != before
    }

    func clear() {
        expiries.removeAll()
    }
}

/// Bounded in-memory LRU score cache keyed by task revision, provider, question version, and the
/// exact canonical classifier payload.
struct ScoreCache {
    let limit: Int
    private var values: [String: (score: Double, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(limit: Int) {
        self.limit = limit
    }

    static func key(revision: Int, provider: String, question: String, input: String) -> String {
        "\(revision)|\(provider)|\(question)|\(input)"
    }

    mutating func get(_ key: String) -> Double? {
        guard let entry = values[key] else { return nil }
        clock += 1
        values[key] = (entry.score, clock)
        return entry.score
    }

    func peek(_ key: String) -> Double? { values[key]?.score }

    mutating func set(_ key: String, _ value: Double) {
        clock += 1
        values[key] = (value, clock)
        if values.count > limit, let oldest = values.min(by: { $0.value.used < $1.value.used })?.key {
            values[oldest] = nil
        }
    }

    mutating func removeAll() {
        values.removeAll()
    }
}
