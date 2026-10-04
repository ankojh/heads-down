import Foundation

// Source-aware lifecycle for calendar automation. The calendar can start a session only when none
// exists, and can update or end only a session it started. Typed tasks, Stop, and pauses always win.
// Nothing here prompts: readiness problems come back as text for the automation status.

extension SessionController {
    /// A session the user started or took over (running, paused, or starting).
    var hasManualSession: Bool { runState != .stopped && taskSource == .manual && pendingCalendarStart == nil }

    /// nil when an automatic start could proceed without any dialog.
    func calendarReadiness() -> String? {
        if !(screenRecordingGranted || Permissions.screenRecordingGranted) {
            return "Screen Recording permission needed"
        }
        if provider.sendsTextOffDevice, !UserDefaults.standard.bool(forKey: Self.jevConsentKey) {
            return "Jev consent needed (choose a classifier in the panel)"
        }
        return nil
    }

    /// Starts a calendar-owned session. `stillWanted` is checked after every await, so a manual
    /// action, stop, suppression, or the event ending meanwhile wins. Returns a problem, or nil.
    func startCalendarTask(
        _ brief: FocusBrief, occurrence: CalendarOccurrence, stillWanted: @escaping () -> Bool
    ) async -> String? {
        guard runState == .stopped else { return "a session is already running" }
        if let problem = calendarReadiness() { return problem }
        pendingCalendarStart = occurrence
        defer { pendingCalendarStart = nil }
        runState = .requestingPermissions
        activity = "Starting from your calendar"
        do {
            _ = try await capturer.refreshContent(force: true)
            screenRecordingGranted = true
        } catch {
            if runState == .requestingPermissions {
                runState = .stopped
                activity = "Idle"
            }
            return "screen capture unavailable"
        }
        guard runState == .requestingPermissions else { return "cancelled" }
        guard stillWanted() else {
            runState = .stopped
            activity = "Idle"
            return "cancelled"
        }
        accessibilityGranted = Permissions.accessibilityGranted
        activate(task: brief.text, source: .calendar(occurrence))
        return nil
    }

    /// Replaces the task of the calendar-owned session for `occurrence` (a real topic change). One
    /// task revision; incompatible region scores are invalidated as for any task change.
    @discardableResult
    func updateCalendarTask(_ brief: FocusBrief, occurrence: CalendarOccurrence) -> Bool {
        guard taskSource == .calendar(occurrence), runState != .stopped, brief.text != currentTask else { return false }
        changeTask(to: brief.text)
        log(["event": "calendar_task_updated"])
        return true
    }

    /// Ends the session only if `occurrence` still owns it. Not a user stop: nothing is suppressed.
    func endCalendarTask(_ occurrence: CalendarOccurrence, reason: String) {
        guard taskSource == .calendar(occurrence), runState != .stopped else { return }
        stop(cause: .calendar(reason))
    }
}
