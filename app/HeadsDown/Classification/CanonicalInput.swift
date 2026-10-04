import Foundation

/// Builds the exact classifier payload once and derives its cache key from that same payload,
/// so a harmless whitespace change doesn't miss the cache and a change the model can't see
/// (beyond the truncation point) doesn't either. Punctuation, case, and numbers are preserved
/// because they can change meaning.
enum CanonicalInput {
    static let schemaVersion = "input-v2"
    static let maxTextChars = 1200

    /// NFC, whitespace collapsed within lines, blank lines dropped, then truncated.
    static func text(_ raw: String) -> String {
        let lines = raw.precomposedStringWithCanonicalMapping
            .components(separatedBy: .newlines)
            .map(collapseWhitespace)
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(maxTextChars))
    }

    /// NFC and whitespace collapsed. A leading unread counter such as "(3) " or "(12+) " is removed:
    /// a generic title decoration that changes often without changing what the page is.
    static func title(_ raw: String) -> String {
        let collapsed = collapseWhitespace(raw.precomposedStringWithCanonicalMapping)
        guard let match = collapsed.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) else {
            return collapsed
        }
        return String(collapsed[match.upperBound...])
    }

    static func app(_ raw: String) -> String {
        collapseWhitespace(raw.precomposedStringWithCanonicalMapping)
    }

    /// Key for already-canonical values.
    static func key(app: String, title: String, text: String) -> String {
        Fingerprint.of(normalized: [schemaVersion, app, title, text].joined(separator: "\u{1f}"))
    }

    private static func collapseWhitespace(_ string: String) -> String {
        string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
