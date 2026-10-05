import Foundation

/// The selected event's relevant fields after sanitizing: what a brief may be built from.
/// Attendees, join links, passcodes, phone numbers, and emails never get this far. `links` holds
/// the event's own public http(s) links (no call links, no private hosts) for the brief agent; they
/// never appear in a brief.
struct SanitizedEvent: Hashable {
    let title: String
    let agenda: String
    let location: String?
    let links: [URL]
    let activity: EventActivity
}

/// Turns sanitized event fields into the task brief. Implementations get only sanitized fields of
/// the one selected event (plus the user's answer to an earlier question, if any) and can't change
/// app state; whatever they return is bounded and scrubbed again by `CalendarContextBuilder.finish`.
@MainActor
protocol CalendarContextCompressor {
    var id: String { get }
    func brief(from event: SanitizedEvent, answer: String?) async -> FocusBrief
}

/// Default: deterministic, on-device. Keeps the title and named agenda items; adds nothing.
struct LocalBriefCompressor: CalendarContextCompressor {
    let id = "local-v1"

    func brief(from event: SanitizedEvent, answer: String?) async -> FocusBrief {
        let fingerprint = CalendarContextBuilder.fingerprint(event, compressorID: id)
        if let reason = CalendarContextBuilder.insufficiency(event) {
            return FocusBrief(text: "", fingerprint: fingerprint, compressorID: id, activity: .insufficientContext,
                              insufficientReason: reason)
        }
        var text = event.activity == .meeting ? "Taking part in the meeting \"\(event.title)\"" : event.title
        if !event.agenda.isEmpty { text += " — \(event.agenda)" }
        if let location = event.location { text += " at \(location)" }
        return FocusBrief(
            text: String(text.prefix(CalendarContextBuilder.maxBriefChars)), fingerprint: fingerprint,
            compressorID: id, activity: event.activity, insufficientReason: nil)
    }
}

/// Sanitizing and activity rules. Event text is untrusted (often written by someone else): it is
/// only ever data for the brief, never an instruction to the app.
enum CalendarContextBuilder {
    /// The brief is repeated in every region request, so it stays small.
    static let maxBriefChars = 400
    static let maxTitleChars = 120
    static let maxAgendaChars = 260

    private static let genericTitles: Set<String> = [
        "busy", "meeting", "event", "call", "block", "blocked", "hold", "focus", "focus time", "work",
        "appointment", "tbd", "untitled", "no title", "sync", "catch up", "chat", "1 1", "one on one",
        "private", "do not book", "dnd", "deep work",
    ]
    private static let personalWords = [
        "lunch", "dinner", "breakfast", "gym", "workout", "doctor", "dentist", "birthday", "vacation",
        "holiday", "commute", "flight", "haircut", "personal", "nap", "break", "pickup", "school run",
    ]
    private static let studyWords = [
        "study", "exam", "quiz", "revision", "revise", "lecture", "class", "homework", "course", "reading",
        "learn", "tutorial", "seminar", "assignment",
    ]
    /// Lines that are meeting boilerplate rather than topic.
    private static let boilerplate = try? NSRegularExpression(
        pattern: #"(join|meeting id|passcode|password|\bpin\b|dial|phone|tel:|zoom|meet\.google|teams|webex|"#
            + #"invitation from google|learn more|reply for|forwarding this|guest list|unsubscribe|-::~)"#,
        options: [.caseInsensitive])
    private static let scrubPatterns = [
        #"https?://\S+"#, #"www\.\S+"#, #"[\w.+-]+@[\w-]+\.[\w.]+"#, #"\+?\d[\d\s().-]{6,}\d"#, #"\b\d{5,}\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func sanitize(_ event: CalendarEvent) -> SanitizedEvent {
        let title = String(scrub(event.summary ?? "").prefix(maxTitleChars))
        let agendaLines = htmlToText(event.description ?? "")
            .components(separatedBy: .newlines)
            .filter { line in
                let range = NSRange(line.startIndex..., in: line)
                return boilerplate?.firstMatch(in: line, range: range) == nil
            }
            .compactMap { line -> String? in
                let cleaned = scrub(line)
                let words = cleaned.split(separator: " ").count
                // A line that was mostly a link, address, or number leaves only connective words behind.
                if cleaned != line.split(whereSeparator: \.isWhitespace).joined(separator: " "), words < 4 { return nil }
                return cleaned.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count >= 3 ? cleaned : nil
            }
        let agenda = String(agendaLines.reduce("") { joined, line in
            guard !joined.isEmpty else { return line }
            return joined + (joined.last.map { ".!?;:".contains($0) } == true ? " " : "; ") + line
        }.prefix(maxAgendaChars))
        return SanitizedEvent(
            title: title, agenda: agenda, location: meaningfulLocation(event.location),
            links: links(in: event), activity: activity(event, title: title))
    }

    static let maxLinks = 5
    private static let linkPattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>()\[\]]+"#)
    /// Hosts whose links are joining instructions or calendar plumbing, not topic.
    private static let plumbingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com",
        "facetime.apple.com", "calendar.google.com", "maps.google.com", "goo.gl", "aka.ms", "outlook.office",
    ]

    /// Public http(s) links from the event's URL field and description, in order, deduplicated.
    static func links(in event: CalendarEvent) -> [URL] {
        let text = [event.url?.absoluteString, event.description].compactMap { $0 }.joined(separator: "\n")
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [URL] = []
        for match in linkPattern?.matches(in: text, range: range) ?? [] {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let raw = String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw), isFetchable(url), seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
            if result.count == maxLinks { break }
        }
        return result
    }

    /// http(s) on a public-looking host: no loopback, link-local, private ranges, or `.local` names.
    static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil
        else { return false }
        if plumbingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || !host.contains(".") {
            return false
        }
        if host.contains(":") { return false }  // IPv6 literal
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
            case (172, let b) where (16...31).contains(b): return false
            case (100, let b) where (64...127).contains(b): return false
            default: break
            }
        }
        return true
    }

    /// Bounds and scrubs any brief text before it becomes the task (agent output included): no
    /// links, emails, or phone numbers, one line, at most `maxBriefChars`.
    static func finish(_ text: String) -> String {
        let flattened = text.components(separatedBy: .newlines).joined(separator: " ")
        return String(scrub(flattened).prefix(maxBriefChars)).trimmingCharacters(in: .whitespaces)
    }

    static func activity(_ event: CalendarEvent, title: String) -> EventActivity {
        if event.eventType == "focusTime" { return .focus }
        let lower = title.lowercased()
        if personalWords.contains(where: { lower.contains($0) }) { return .personal }
        if studyWords.contains(where: { lower.contains($0) }) { return .study }
        if event.conferenceName != nil || event.selfResponse != nil { return .meeting }
        return .work
    }

    /// nil when the event says enough to focus on.
    static func insufficiency(_ event: SanitizedEvent) -> String? {
        if event.activity == .personal { return "personal event" }
        let normalized = Fingerprint.normalize(event.title)
        if normalized.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count < 3 {
            return event.agenda.isEmpty ? "no readable title or details" : nil
        }
        if genericTitles.contains(normalized), event.agenda.isEmpty {
            return "generic title with no details"
        }
        return nil
    }

    static func fingerprint(_ event: SanitizedEvent, compressorID: String) -> String {
        Fingerprint.of(normalized: [
            "calendar-brief-v2", compressorID, event.title, event.agenda, event.location ?? "",
            event.links.map(\.absoluteString).joined(separator: "\u{1f}"), event.activity.rawValue,
        ].joined(separator: "\u{1f}"))
    }

    /// Tags dropped, a few entities decoded. No HTML engine: nothing is executed or loaded.
    private static func htmlToText(_ html: String) -> String {
        var text = html
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</li>", "</div>", "<li>"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
    }

    static func scrub(_ text: String) -> String {
        var result = text
        for pattern in scrubPatterns {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:;,|"))
    }

    /// Short place names only ("Library"); rooms, addresses, and call links aren't topics.
    private static func meaningfulLocation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = scrub(raw)
        let lower = text.lowercased()
        let callWords = ["room", "zoom", "meet", "teams", "call", "floor", "http", "online", "virtual"]
        guard !text.isEmpty, text.count <= 40, !text.contains(where: \.isNumber),
              !callWords.contains(where: { lower.contains($0) })
        else { return nil }
        return text
    }
}
