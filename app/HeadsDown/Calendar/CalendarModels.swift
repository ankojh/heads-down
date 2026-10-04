import Foundation

/// Stable identity of one event occurrence, scoped to a connection and calendar. Never derived from
/// the ETag or display times, so RSVP churn or a reschedule can't escape a suppression.
struct CalendarOccurrence: Hashable, Codable {
    /// Random per connection (no profile scope is requested, so the account itself isn't known).
    let connectionID: String
    let calendarID: String
    /// Google's event instance ID (with `singleEvents=true` it already distinguishes occurrences of a
    /// recurring series and stays the same when one occurrence is moved).
    let instanceID: String
    /// iCalUID + original start: the same invitation mirrored on several calendars.
    let mirrorKey: String?

    var storageKey: String { "\(connectionID)|\(calendarID)|\(instanceID)" }
}

/// Who chose the task the session is focusing on.
enum TaskSource: Equatable {
    case manual
    case calendar(CalendarOccurrence)

    var occurrence: CalendarOccurrence? {
        if case .calendar(let occurrence) = self { return occurrence }
        return nil
    }
}

enum EventActivity: String {
    case focus, study, work, meeting, personal
    case insufficientContext = "insufficient_context"
}

/// One event from the Calendar API, parsed. Only fields needed for eligibility and the brief.
struct CalendarEvent {
    let occurrence: CalendarOccurrence
    let status: String
    let summary: String?
    let description: String?
    let location: String?
    /// nil for all-day events (they have a date, not a time).
    let start: Date?
    let end: Date?
    let isAllDay: Bool
    let eventType: String
    let transparency: String
    let visibility: String
    /// Response of the attendee marked `self` on this calendar's copy, if any.
    let selfResponse: String?
    let organizerIsSelf: Bool
    let attachmentTitles: [String]
    let conferenceName: String?
    /// ETag/updated: when they change the event is inspected again (not automatically rescored).
    let etag: String?
}

/// The task text given to the classifier for a calendar-owned session, with its provenance.
struct FocusBrief: Equatable {
    /// Exactly what's sent as the task (bounded, sanitized).
    let text: String
    /// Hash of the sanitized relevant fields + compressor version. Equal fingerprints mean the
    /// task is unchanged, so nothing is reclassified.
    let fingerprint: String
    let compressorID: String
    let activity: EventActivity
    /// Set when the event doesn't say enough to focus on; auto-start stays inactive.
    let insufficientReason: String?
}

/// What calendar automation is doing, for the panel.
enum AutomationStatus: Equatable {
    case disconnected
    case needsAuthorization(String)
    case disabled
    case checking
    case noEvent
    case notEligible(String)
    case insufficientContext
    case preparing
    case active(until: Date)
    case skipped
    case manualPriority
    case pausedByUser
    case blocked(String)
    case degraded(String)

    var label: String {
        switch self {
        case .disconnected: return "Not connected"
        case .needsAuthorization(let why): return "Authorization needed — \(why)"
        case .disabled: return "Auto-start is off"
        case .checking: return "Checking the current event…"
        case .noEvent: return "Watching · no current event"
        case .notEligible(let why): return "Watching · current event not used (\(why))"
        case .insufficientContext: return "Current event has insufficient topic information"
        case .preparing: return "Preparing the current event"
        case .active(let until):
            return "Focusing on the current event until \(until.formatted(date: .omitted, time: .shortened))"
        case .skipped: return "Skipped for this event (you stopped it)"
        case .manualPriority: return "Your typed task has priority"
        case .pausedByUser: return "Paused by you — calendar auto-start waits until you resume"
        case .blocked(let why): return "Can't start automatically: \(why)"
        case .degraded(let why): return "Calendar unavailable: \(why)"
        }
    }
}
