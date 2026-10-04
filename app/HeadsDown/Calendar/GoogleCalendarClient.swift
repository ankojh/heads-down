import Foundation

enum CalendarFetchError: Error {
    case auth(CalendarAuthError)
    case unauthorized
    case rateLimited
    case server(Int)
    case network
    case malformed

    /// Short category for status and logs; never a response body.
    var category: String {
        switch self {
        case .auth(let error): return error.errorDescription ?? "authorization"
        case .unauthorized: return "authorization rejected"
        case .rateLimited: return "rate limited"
        case .server(let status): return "Google error \(status)"
        case .network: return "offline or unreachable"
        case .malformed: return "unexpected response"
        }
    }

    var needsAuthorization: Bool {
        switch self {
        case .unauthorized: return true
        case .auth(let error): return [.invalidGrant, .notConnected, .notConfigured].contains(error)
        default: return false
        }
    }
}

struct CalendarFetch {
    let events: [CalendarEvent]
    /// False when paging stopped at the bound before Google's last page.
    let complete: Bool
    let fetchedAt: Date
    let ms: Double
}

/// Read-only Calendar REST access for current-event candidates only.
///
/// `events.list` with `singleEvents=true` (recurring events expanded into instances), a narrow window
/// around now (`timeMin` bounds event *end*, `timeMax` bounds event *start*, both exclusive), and a
/// partial `fields` selection that leaves out attendee identities and conference links. The actual
/// "active now" test (`start <= now < end`) happens locally in `CurrentEventResolver`.
struct GoogleCalendarClient {
    static let window: TimeInterval = 60
    static let maxPages = 4
    static let fields = "items(id,iCalUID,status,summary,description,location,start,end,eventType,transparency,"
        + "visibility,attendees(self,responseStatus),organizer(self),originalStartTime,attachments(title),"
        + "conferenceData(conferenceSolution(name)),etag),nextPageToken"

    let auth: GoogleCalendarAuth

    func currentEvents(calendarID: String, connectionID: String, now: Date) async throws -> CalendarFetch {
        let started = Date()
        var events: [CalendarEvent] = []
        var pageToken: String?
        var pages = 0
        repeat {
            let page = try await fetchPage(calendarID: calendarID, now: now, pageToken: pageToken)
            events += (page["items"] as? [[String: Any]] ?? []).compactMap {
                Self.parse($0, calendarID: calendarID, connectionID: connectionID)
            }
            pageToken = page["nextPageToken"] as? String
            pages += 1
        } while pageToken != nil && pages < Self.maxPages
        return CalendarFetch(events: events, complete: pageToken == nil, fetchedAt: now, ms: elapsedMs(since: started))
    }

    private func fetchPage(calendarID: String, now: Date, pageToken: String?) async throws -> [String: Any] {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/@")
        let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "primary"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = "/calendar/v3/calendars/\(encodedID)/events"
        let formatter = ISO8601DateFormatter()
        var query = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: formatter.string(from: now)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: now.addingTimeInterval(Self.window))),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "fields", value: Self.fields),
        ]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = query
        guard let url = components.url else { throw CalendarFetchError.malformed }

        for attempt in 0..<2 {
            let token: String
            do {
                token = try await auth.validAccessToken(forceRefresh: attempt > 0)
            } catch let error as CalendarAuthError {
                throw CalendarFetchError.auth(error)
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw CalendarFetchError.network
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CalendarFetchError.malformed
                }
                return json
            case 401:
                // One forced refresh, then give up: no retry loop on revoked credentials.
                if attempt == 0 { continue }
                throw CalendarFetchError.unauthorized
            case 403, 429:
                let body = String(data: data, encoding: .utf8) ?? ""
                if status == 429 || body.contains("ateLimit") { throw CalendarFetchError.rateLimited }
                throw CalendarFetchError.unauthorized
            default:
                throw CalendarFetchError.server(status)
            }
        }
        throw CalendarFetchError.unauthorized
    }

    // MARK: - Parsing

    static func parse(_ item: [String: Any], calendarID: String, connectionID: String) -> CalendarEvent? {
        guard let id = item["id"] as? String else { return nil }
        let start = item["start"] as? [String: Any] ?? [:]
        let end = item["end"] as? [String: Any] ?? [:]
        let original = (item["originalStartTime"] as? [String: Any]).flatMap {
            ($0["dateTime"] as? String) ?? ($0["date"] as? String)
        }
        let startText = (start["dateTime"] as? String) ?? (start["date"] as? String) ?? ""
        let mirrorKey = (item["iCalUID"] as? String).map { "\($0)|\(original ?? startText)" }
        let attendees = item["attendees"] as? [[String: Any]] ?? []
        let selfAttendee = attendees.first { $0["self"] as? Bool == true }
        let attachments = (item["attachments"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        let conference = ((item["conferenceData"] as? [String: Any])?["conferenceSolution"] as? [String: Any])?["name"]
        return CalendarEvent(
            occurrence: CalendarOccurrence(
                connectionID: connectionID, calendarID: calendarID, instanceID: id, mirrorKey: mirrorKey),
            status: item["status"] as? String ?? "confirmed",
            summary: item["summary"] as? String,
            description: item["description"] as? String,
            location: item["location"] as? String,
            start: (start["dateTime"] as? String).flatMap(parseDate),
            end: (end["dateTime"] as? String).flatMap(parseDate),
            isAllDay: start["dateTime"] == nil && start["date"] != nil,
            eventType: item["eventType"] as? String ?? "default",
            transparency: item["transparency"] as? String ?? "opaque",
            visibility: item["visibility"] as? String ?? "default",
            selfResponse: selfAttendee?["responseStatus"] as? String,
            organizerIsSelf: (item["organizer"] as? [String: Any])?["self"] as? Bool ?? false,
            attachmentTitles: attachments,
            conferenceName: conference as? String,
            etag: item["etag"] as? String)
    }

    /// RFC 3339 with an explicit offset, with or without fractional seconds. Absolute instants, so
    /// DST and events crossing midnight compare correctly.
    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
