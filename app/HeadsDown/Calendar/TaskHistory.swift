import Foundation

/// Recent focus tasks (typed and calendar briefs), for the brief agent's `recent_tasks` tool.
/// Recorded only while the local brief agent is turned on, kept on this Mac in Application Support,
/// never logged, and cleared from the Inspector or by turning the agent off.
@MainActor
final class TaskHistory {
    static let shared = TaskHistory()
    static let maxEntries = 20

    struct Entry: Codable, Equatable {
        let text: String
        let source: String
        let at: Date
    }

    private(set) var entries: [Entry] = []
    private let url: URL

    init(url: URL = TaskHistory.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HeadsDown/task-history.json")
    }

    func record(_ text: String, source: String) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CalendarContextBuilder.maxBriefChars))
        guard !text.isEmpty else { return }
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, source: source, at: Date()), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
    }

    func recent(_ limit: Int) -> [Entry] {
        Array(entries.prefix(limit))
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
