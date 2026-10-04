import Foundation

/// Bounded local JSONL log of cycle metadata: session-local IDs, counts, source flags, timings,
/// scores/actions, skip reasons, and error categories. By design it never receives screen text,
/// task text, window titles, URLs, or images. Nothing is uploaded.
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()
    static let maxBytes = 2_000_000

    let url: URL
    private let queue = DispatchQueue(label: "HeadsDown.diagnostics")

    private init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HeadsDown", isDirectory: true)
        url = logs.appendingPathComponent("cycles.jsonl")
    }

    func append(_ record: [String: Any]) {
        var record = record
        record["ts"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(record),
              var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        line.append(0x0A)
        let url = url
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes {
                let previous = url.deletingPathExtension().appendingPathExtension("1.jsonl")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    func deleteAll() {
        let url = url
        queue.async {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("1.jsonl"))
        }
    }
}
