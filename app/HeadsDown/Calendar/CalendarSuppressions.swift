import Foundation

/// Occurrences the user stopped ("Skipped for this event"), persisted across restarts with an expiry
/// at the event's end. Keyed by stable occurrence identity (and the mirrored-invitation key), never
/// by ETag, so an RSVP or edit can't bypass it. Stores only IDs and expiry times, no event content.
struct CalendarSuppressions {
    static let defaultsKey = "calendarSuppressions"
    static let maxEntries = 200

    private var stored: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:] }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    private func keys(_ occurrence: CalendarOccurrence) -> [String] {
        var keys = ["occ|\(occurrence.storageKey)"]
        if let mirror = occurrence.mirrorKey { keys.append("mir|\(occurrence.connectionID)|\(mirror)") }
        return keys
    }

    func suppress(_ event: CalendarEvent) {
        var entries = stored
        let expiry = (event.end ?? Date().addingTimeInterval(12 * 3600)).timeIntervalSince1970
        for key in keys(event.occurrence) { entries[key] = expiry }
        if entries.count > Self.maxEntries {
            let oldest = entries.sorted { $0.value < $1.value }.prefix(entries.count - Self.maxEntries)
            for entry in oldest { entries[entry.key] = nil }
        }
        stored = entries
    }

    func contains(_ event: CalendarEvent) -> Bool {
        let entries = stored
        let now = Date().timeIntervalSince1970
        return keys(event.occurrence).contains { (entries[$0] ?? 0) > now }
    }

    func remove(_ occurrence: CalendarOccurrence) {
        var entries = stored
        for key in keys(occurrence) { entries[key] = nil }
        stored = entries
    }

    func prune() {
        let now = Date().timeIntervalSince1970
        stored = stored.filter { $0.value > now }
    }

    func removeAll() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
