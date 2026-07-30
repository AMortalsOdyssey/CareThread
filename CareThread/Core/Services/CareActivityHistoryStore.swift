import Foundation

extension Notification.Name {
    static let careActivityHistoryDidChange =
        Notification.Name("carethread.activityHistoryDidChange")
}

struct CareActivityHistory: Equatable {
    var lastBackupAt: Date? = nil
    var lastNearbyMigrationAt: Date? = nil
}

/// Stores non-sensitive continuity metadata only. Health content and member
/// identifiers never enter UserDefaults; the actual backup/migration payloads
/// stay in their protected file stores.
@MainActor
final class CareActivityHistoryStore {
    private enum Key {
        static let lastBackupAt = "carethread.activity.lastBackupAt"
        static let lastNearbyMigrationAt =
            "carethread.activity.lastNearbyMigrationAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot() -> CareActivityHistory {
        CareActivityHistory(
            lastBackupAt: date(forKey: Key.lastBackupAt),
            lastNearbyMigrationAt: date(
                forKey: Key.lastNearbyMigrationAt
            )
        )
    }

    func recordBackup(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.lastBackupAt)
        NotificationCenter.default.post(
            name: .careActivityHistoryDidChange,
            object: nil
        )
    }

    func recordNearbyMigration(at date: Date = Date()) {
        defaults.set(
            date.timeIntervalSince1970,
            forKey: Key.lastNearbyMigrationAt
        )
        NotificationCenter.default.post(
            name: .careActivityHistoryDidChange,
            object: nil
        )
    }

    private func date(forKey key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let interval = defaults.double(forKey: key)
        guard interval.isFinite, interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }
}
