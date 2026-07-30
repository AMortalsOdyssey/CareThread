import Foundation
import Testing
@testable import CareThread

@MainActor
struct M4M5SystemAdapterTests {
    private let patientID = UUID()
    private let now = CTDate.make(2026, 7, 30, hour: 23, minute: 50)

    @Test("查询通知状态不会请求权限")
    func statusCheckDoesNotRequestPermission() async {
        let center = M45FakeNotificationCenter(status: .notDetermined)
        let status = await AppleReminderScheduler(
            center: center
        ).permissionStatus()
        #expect(status == .notDetermined)
        #expect(center.requestCount == 0)
    }

    @Test("通知权限拒绝后返回系统设置提示且不排期")
    func deniedNotificationPermission() async throws {
        let center = M45FakeNotificationCenter(status: .denied)
        let result = try await AppleReminderScheduler(
            center: center,
            now: { self.now }
        ).scheduleMedicationUserInitiated(
            medication: medication()
        )
        #expect(result == .permissionDenied(openSettingsRequired: true))
        #expect(center.added.isEmpty)
        #expect(center.requestCount == 0)
    }

    @Test("用户主动开启时未决定权限只请求一次")
    func userInitiatedPermissionRequest() async throws {
        let center = M45FakeNotificationCenter(
            status: .notDetermined,
            requestResult: true
        )
        _ = try await AppleReminderScheduler(
            center: center,
            now: { self.now }
        ).scheduleMedicationUserInitiated(
            medication: medication()
        )
        #expect(center.requestCount == 1)
        #expect(!center.added.isEmpty)
    }

    @Test("B15 23:50 创建每日一次提醒首发为次日 08:00")
    func lateNightSchedulesNextMorning() async throws {
        var calendar = CTDate.calendar
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let center = M45FakeNotificationCenter(status: .authorized)
        let scheduler = AppleReminderScheduler(
            center: center,
            now: { self.now },
            calendar: calendar
        )
        _ = try await scheduler.scheduleMedicationUserInitiated(
            medication: medication()
        )
        let first = try #require(center.added.first)
        let values = calendar.dateComponents(
            [.day, .hour, .minute],
            from: first.fireDate
        )
        #expect(values.day == 31)
        #expect(values.hour == 8)
        #expect(values.minute == 0)
    }

    @Test("系统 64 条预算扣除其他提醒后严格截断")
    func systemBudgetIsCappedAt64() async throws {
        let unrelated = (0..<63).map {
            LocalNotificationRequest(
                identifier: "other.\($0)",
                fireDate: now,
                timezoneIdentifier: TimeZone.current.identifier,
                title: "x",
                body: "x",
                userInfo: [:]
            )
        }
        let center = M45FakeNotificationCenter(
            status: .authorized,
            pending: unrelated
        )
        let result = try await AppleReminderScheduler(
            center: center,
            now: { self.now }
        ).scheduleMedicationUserInitiated(
            medication: medication()
        )
        #expect(result == .scheduled(requestCount: 1, truncated: true))
        #expect(center.pending.count == 64)
    }

    @Test("复查提醒生成前一天 09:00 和当天 08:00")
    func followUpNotificationDates() {
        var calendar = CTDate.calendar
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let scheduler = AppleReminderScheduler(
            center: M45FakeNotificationCenter(status: .authorized),
            calendar: calendar
        )
        let dates = scheduler.followUpNotificationDates(
            plannedDate: CTDate.make(2026, 8, 15)
        )
        let components = dates.map {
            calendar.dateComponents([.day, .hour], from: $0)
        }
        #expect(components[0].day == 14)
        #expect(components[0].hour == 9)
        #expect(components[1].day == 15)
        #expect(components[1].hour == 8)
    }

    @Test("新增请求失败会撤销新增并恢复原提醒")
    func notificationReconcileRollsBack() async {
        let medication = medication()
        let old = LocalNotificationRequest(
            identifier: "\(AppleReminderScheduler.managedPrefix)\(medication.id.uuidString.lowercased()).old",
            fireDate: now.addingTimeInterval(3_600),
            timezoneIdentifier: TimeZone.current.identifier,
            title: "old",
            body: "old",
            userInfo: [:]
        )
        let center = M45FakeNotificationCenter(
            status: .authorized,
            pending: [old],
            failOnAddNumber: 1
        )
        await #expect(throws: AppleReminderSchedulerError.systemScheduleFailed) {
            try await AppleReminderScheduler(
                center: center,
                now: { self.now }
            ).scheduleMedicationUserInitiated(medication: medication)
        }
        #expect(center.pending.contains(where: { $0.identifier == old.identifier }))
    }

    @Test("关闭业务提醒会移除该业务的系统请求")
    func disabledReminderRemovesManagedRequests() async throws {
        let medication = medication(reminderEnabled: false)
        let identifier = "\(AppleReminderScheduler.managedPrefix)\(medication.id.uuidString.lowercased()).old"
        let center = M45FakeNotificationCenter(
            status: .authorized,
            pending: [
                LocalNotificationRequest(
                    identifier: identifier,
                    fireDate: now,
                    timezoneIdentifier: TimeZone.current.identifier,
                    title: "",
                    body: "",
                    userInfo: [:]
                )
            ]
        )
        let result = try await AppleReminderScheduler(
            center: center
        ).scheduleMedicationUserInitiated(medication: medication)
        #expect(result == .disabled)
        #expect(center.pending.isEmpty)
    }

    @Test("日历权限拒绝不会写入事件")
    func deniedCalendarPermission() async throws {
        let store = M45FakeCalendarStore(status: .denied)
        let result = try await CalendarExportService(
            store: store
        ).addFollowUpUserInitiated(
            followUp(),
            memberName: "虚构成员"
        )
        #expect(result == .permissionDenied(openSettingsRequired: true))
        #expect(store.saved.isEmpty)
        #expect(store.requestCount == 0)
    }

    @Test("用户明确加入日历时才请求并保存")
    func explicitCalendarExport() async throws {
        let store = M45FakeCalendarStore(
            status: .notDetermined,
            requestResult: true
        )
        let result = try await CalendarExportService(
            store: store
        ).addFollowUpUserInitiated(
            followUp(),
            memberName: "虚构成员"
        )
        #expect(result == .added(eventIdentifier: "fake-event"))
        #expect(store.requestCount == 1)
        let saved = try #require(store.saved.first)
        #expect(saved.isAllDay)
        #expect(saved.title.contains("甲功"))
        #expect(saved.notes?.contains("不提供诊断") == true)
    }

    private func medication(reminderEnabled: Bool = true) -> Medication {
        Medication(
            patientId: patientID,
            name: "虚构药",
            doseValue: 75,
            doseUnit: "µg",
            frequency: .dailyOne,
            startDate: CTDate.make(2026, 7, 1),
            reminderEnabled: reminderEnabled,
            reminderTimes: reminderEnabled
                ? [ReminderTime(hour: 8, minute: 0)]
                : []
        )
    }

    private func followUp() -> FollowUp {
        FollowUp(
            patientId: patientID,
            plannedDate: CTDate.make(2026, 8, 15),
            items: ["甲功"],
            reminderEnabled: true
        )
    }
}

private final class M45FakeNotificationCenter:
    LocalNotificationCenterAdapting {
    var status: ReminderAuthorizationStatus
    var requestResult: Bool
    var pending: [LocalNotificationRequest]
    var added: [LocalNotificationRequest] = []
    var requestCount = 0
    var addCount = 0
    var failOnAddNumber: Int?

    init(
        status: ReminderAuthorizationStatus,
        requestResult: Bool = false,
        pending: [LocalNotificationRequest] = [],
        failOnAddNumber: Int? = nil
    ) {
        self.status = status
        self.requestResult = requestResult
        self.pending = pending
        self.failOnAddNumber = failOnAddNumber
    }

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if requestResult { status = .authorized }
        return requestResult
    }

    func pendingRequests() async -> [LocalNotificationRequest] {
        pending
    }

    func add(_ request: LocalNotificationRequest) async throws {
        addCount += 1
        if addCount == failOnAddNumber {
            throw M45FakeError.injected
        }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
        added.append(request)
    }

    func remove(identifiers: [String]) async {
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

private final class M45FakeCalendarStore: CalendarEventStoreAdapting {
    var status: ReminderAuthorizationStatus
    var requestResult: Bool
    var requestCount = 0
    var saved: [CalendarEventDraft] = []

    init(
        status: ReminderAuthorizationStatus,
        requestResult: Bool = false
    ) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> ReminderAuthorizationStatus {
        status
    }

    func requestAccess() async throws -> Bool {
        requestCount += 1
        if requestResult { status = .authorized }
        return requestResult
    }

    func save(_ draft: CalendarEventDraft) throws -> String {
        saved.append(draft)
        return "fake-event"
    }
}

private enum M45FakeError: Error {
    case injected
}
