import EventKit
import Foundation

enum CalendarFetchError: Error {
    case notAuthorized

    /// Short category for status and logs; never event content.
    var category: String {
        switch self {
        case .notAuthorized: return "calendar access not granted"
        }
    }
}

struct CalendarFetch {
    let events: [CalendarEvent]
    /// Always true for EventKit (a local query has no paging bound).
    let complete: Bool
    let fetchedAt: Date
    let ms: Double
}

/// Reads current-event candidates from the macOS calendar store (EventKit): every account added in
/// System Settings → Internet Accounts (Google, iCloud, Exchange, …) without OAuth or network calls
/// from Heads Down. macOS syncs those accounts itself, so edits show up after its own sync.
///
/// Only a narrow window around now is queried. The actual "active now" test (`start <= now < end`)
/// happens in `CurrentEventResolver`. Attendee identities are never read beyond "is this me".
@MainActor
final class EventKitCalendarSource {
    static let window: TimeInterval = 60
    static let connectionID = "eventkit"
    /// How often to ask macOS to sync remote calendars (cheap; the OS rate-limits it).
    static let refreshSourcesInterval: TimeInterval = 300

    let store = EKEventStore()
    private var lastSourceRefresh = Date.distantPast

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var wasDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    /// Shows the macOS Calendars prompt the first time; later returns the stored decision.
    func requestAccess() async -> Bool {
        if Self.hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Calendars that can hold the user's own schedule. Subscribed calendars (holidays, sports) are
    /// left out; birthdays are kept so they are recognized and skipped by the resolver.
    var calendars: [EKCalendar] {
        store.calendars(for: .event).filter { $0.type != .subscription }
    }

    func currentEvents(now: Date) throws -> CalendarFetch {
        guard Self.hasAccess else { throw CalendarFetchError.notAuthorized }
        let started = Date()
        if started.timeIntervalSince(lastSourceRefresh) > Self.refreshSourcesInterval {
            store.refreshSourcesIfNecessary()
            lastSourceRefresh = started
        }
        let calendars = calendars
        guard !calendars.isEmpty else {
            return CalendarFetch(events: [], complete: true, fetchedAt: now, ms: elapsedMs(since: started))
        }
        // EventKit returns events overlapping [start, end); a small look-behind catches long events.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.window), end: now.addingTimeInterval(Self.window),
            calendars: calendars)
        let events = store.events(matching: predicate).map(Self.map)
        return CalendarFetch(events: events, complete: true, fetchedAt: now, ms: elapsedMs(since: started))
    }

    // MARK: - Mapping

    private static let callHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                    "webex.com", "whereby.com", "facetime.apple.com"]

    static func map(_ event: EKEvent) -> CalendarEvent {
        let occurrenceDate = event.occurrenceDate ?? event.startDate ?? .distantPast
        let stamp = String(Int(occurrenceDate.timeIntervalSince1970))
        let instance = "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(stamp)"
        let mirrorKey = event.calendarItemExternalIdentifier.map { "\($0)|\(stamp)" }
        let me = event.attendees?.first(where: \.isCurrentUser)
        let callText = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
            .lowercased()
        let isCall = callHosts.contains { callText.contains($0) }
        return CalendarEvent(
            occurrence: CalendarOccurrence(
                connectionID: connectionID, calendarID: event.calendar?.calendarIdentifier ?? "unknown",
                instanceID: instance, mirrorKey: mirrorKey),
            status: status(event.status),
            summary: event.title,
            description: event.notes,
            location: event.location,
            start: event.isAllDay ? nil : event.startDate,
            end: event.isAllDay ? nil : event.endDate,
            isAllDay: event.isAllDay,
            eventType: event.calendar?.type == .birthday || event.birthdayContactIdentifier != nil ? "birthday" : "default",
            transparency: event.availability == .free ? "transparent" : "opaque",
            selfResponse: me.map { response($0.participantStatus) },
            organizerIsSelf: event.organizer?.isCurrentUser ?? (event.attendees?.isEmpty ?? true),
            conferenceName: isCall ? "video call" : nil,
            url: event.url)
    }

    private static func status(_ status: EKEventStatus) -> String {
        switch status {
        case .canceled: return "cancelled"
        case .tentative: return "tentative"
        default: return "confirmed"
        }
    }

    private static func response(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted, .completed, .inProcess: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "declined"
        default: return "needsAction"
        }
    }
}
