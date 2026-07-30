import Foundation
import Testing
@testable import CareThread

@MainActor
struct CareActivityHistoryStoreTests {
    @Test("最近备份与附近迁移时间独立持久化且不写入成员内容")
    func timestampsPersistIndependently() throws {
        let suite = "CareActivityHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CareActivityHistoryStore(defaults: defaults)
        let backup = CTDate.make(2026, 7, 30, hour: 8)
        let migration = CTDate.make(2026, 7, 31, hour: 9)

        #expect(store.snapshot() == CareActivityHistory())
        store.recordBackup(at: backup)
        #expect(store.snapshot().lastBackupAt == backup)
        #expect(store.snapshot().lastNearbyMigrationAt == nil)
        store.recordNearbyMigration(at: migration)

        let reopened = CareActivityHistoryStore(defaults: defaults).snapshot()
        #expect(reopened.lastBackupAt == backup)
        #expect(reopened.lastNearbyMigrationAt == migration)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy {
            !$0.localizedCaseInsensitiveContains("patient")
                && !$0.localizedCaseInsensitiveContains("member")
        })
    }

    @Test("损坏或缺失的时间戳安全显示为从未完成")
    func invalidTimestampIsIgnored() throws {
        let suite = "CareActivityHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            Double.nan,
            forKey: "carethread.activity.lastBackupAt"
        )
        defaults.set(
            -1,
            forKey: "carethread.activity.lastNearbyMigrationAt"
        )

        #expect(
            CareActivityHistoryStore(defaults: defaults).snapshot()
                == CareActivityHistory()
        )
    }
}
