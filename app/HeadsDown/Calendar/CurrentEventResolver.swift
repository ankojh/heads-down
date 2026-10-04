import Foundation

/// Deterministic eligibility and overlap selection for the event active right now. Dates,
/// statuses, and overlaps are decided in code, never by a model.
enum CurrentEventResolver {
    struct Resolution {
        /// The event the automation should follow, if any.
        let selected: CalendarEvent?
        /// Every eligible event active now (mirrored copies collapsed).
        let eligible: [CalendarEvent]
        /// Why the active-now events that weren't eligible were skipped (categories, no content).
        let skippedReasons: [String]
    }

    static func isActive(_ event: CalendarEvent, at now: Date) -> Bool {
        guard let start = event.start, let end = event.end else { return false }
        return start <= now && now < end
    }

    /// nil when eligible; otherwise a short reason category.
    static func ineligibility(_ event: CalendarEvent) -> String? {
        if event.isAllDay { return "all-day" }
        if event.status == "cancelled" { return "cancelled" }
        if event.status != "confirmed" { return "tentative" }
        switch event.eventType {
        case "default", "focusTime": break
        case "outOfOffice": return "out of office"
        case "workingLocation": return "working location"
        case "birthday": return "birthday"
        default: return "\(event.eventType) event"
        }
        if event.transparency == "transparent" { return "marked as free" }
        switch event.selfResponse {
        case "declined": return "declined"
        case "needsAction", "tentative": return "not accepted"
        default: break
        }
        return nil
    }

    /// Keeps `current` while it stays eligible (no switching from poll to poll). Otherwise: events
    /// with usable topic details, then focus time, then events you organize or accepted, then the
    /// most recent start, then instance ID. Simultaneous events are never merged.
    static func resolve(
        _ events: [CalendarEvent], now: Date, keeping current: CalendarOccurrence?,
        usable: (CalendarEvent) -> Bool = { _ in true }
    ) -> Resolution {
        let active = events.filter { isActive($0, at: now) }
        var skipped: [String] = []
        var eligible: [CalendarEvent] = []
        var mirrors = Set<String>()
        for event in active {
            if let reason = ineligibility(event) {
                skipped.append(reason)
                continue
            }
            if let mirror = event.occurrence.mirrorKey, !mirrors.insert(mirror).inserted { continue }
            eligible.append(event)
        }
        if let current, let kept = eligible.first(where: { $0.occurrence == current }) {
            return Resolution(selected: kept, eligible: eligible, skippedReasons: skipped)
        }
        let ranked = eligible.sorted { lhs, rhs in
            let left = rank(lhs) + (usable(lhs) ? 4 : 0), right = rank(rhs) + (usable(rhs) ? 4 : 0)
            if left != right { return left > right }
            let leftStart = lhs.start ?? .distantPast, rightStart = rhs.start ?? .distantPast
            if leftStart != rightStart { return leftStart > rightStart }
            return lhs.occurrence.instanceID < rhs.occurrence.instanceID
        }
        return Resolution(selected: ranked.first, eligible: eligible, skippedReasons: skipped)
    }

    private static func rank(_ event: CalendarEvent) -> Int {
        var score = 0
        if event.eventType == "focusTime" { score += 2 }
        if event.organizerIsSelf || event.selfResponse == "accepted" { score += 1 }
        return score
    }
}
