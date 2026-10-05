import Foundation

/// Stable identity of one event occurrence, scoped to a connection and calendar. Never derived from
/// the ETag or display times, so RSVP churn or a reschedule can't escape a suppression.
struct CalendarOccurrence: Hashable, Codable {
    /// Source namespace ("eventkit"); keeps suppressions from different sources apart.
    let connectionID: String
    /// EventKit calendar identifier.
    let calendarID: String
    /// Event identifier + original occurrence date: distinguishes occurrences of a recurring series
    /// and stays the same when one occurrence is moved.
    let instanceID: String
    /// iCal UID + original start: the same invitation mirrored on several calendars.
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

/// One event from EventKit, mapped. Only fields needed for eligibility and the brief.
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
    /// "default" or "birthday" (EventKit has no focus-time / out-of-office types).
    let eventType: String
    /// "opaque" (busy) or "transparent" (free).
    let transparency: String
    /// The current user's response as an attendee (accepted, declined, tentative, needsAction), if any.
    let selfResponse: String?
    let organizerIsSelf: Bool
    /// Set when the event carries a video-call link or location.
    let conferenceName: String?
    /// The event's URL field, if any (a candidate link for the brief agent).
    let url: URL?
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
    /// A clarifying question the brief agent wants answered (shown in the panel; never blocks focus).
    var question: String? = nil
    /// Why an agent brief fell back to the local one, for the panel (a category, no content).
    var agentNote: String? = nil
}

/// What calendar automation is doing, for the panel.
enum AutomationStatus: Equatable {
    case disconnected
    case needsAuthorization(String)
    case preparingWithAgent
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
        case .disconnected: return "Calendar access not granted"
        case .needsAuthorization(let why): return "Authorization needed — \(why)"
        case .disabled: return "Auto-start is off"
        case .checking: return "Checking the current event…"
        case .noEvent: return "Watching · no current event"
        case .notEligible(let why): return "Watching · current event not used (\(why))"
        case .insufficientContext: return "Current event has insufficient topic information"
        case .preparing: return "Preparing the current event"
        case .preparingWithAgent: return "Writing a focus brief with the local agent…"
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
