import Foundation
import Testing
@testable import CareThread

struct M4ReminderPlannerTests {
    @Test("每日 1/2/3 次只有可编辑默认建议，按需不自动排期")
    func defaultSuggestionsAndAsNeeded() throws {
        #expect(
            ReminderPlanner.suggestedTimes(for: .dailyOne) ==
            [ReminderTime(hour: 8, minute: 0)]
        )
        #expect(
            ReminderPlanner.suggestedTimes(for: .dailyTwo) ==
            [
                ReminderTime(hour: 8, minute: 0),
                ReminderTime(hour: 20, minute: 0)
            ]
        )
        #expect(
            ReminderPlanner.suggestedTimes(for: .dailyThree) ==
            [
                ReminderTime(hour: 8, minute: 0),
                ReminderTime(hour: 13, minute: 0),
                ReminderTime(hour: 20, minute: 0)
            ]
        )
        #expect(ReminderPlanner.suggestedTimes(for: .asNeeded).isEmpty)

        let start = makeLocal(2026, 1, 1, 0, 0, "Asia/Shanghai")
        let plan = try ReminderPlanner.plan(
            input(
                frequency: .asNeeded,
                times: [],
                start: start,
                windowEnd: start.addingTimeInterval(7 * 86_400)
            )
        )
        #expect(plan.requests.isEmpty)
        #expect(plan.isAsNeeded)
        #expect(plan.cadence == .asNeeded)
    }

    @Test("每日、隔日和每周 N 次按固定日历生成可解释请求")
    func cadenceMapping() throws {
        let timezone = "Asia/Shanghai"
        let start = makeLocal(2026, 1, 5, 0, 0, timezone)
        let end = makeLocal(2026, 1, 11, 23, 59, timezone)

        let daily = try ReminderPlanner.plan(
            input(
                frequency: .dailyTwo,
                times: [
                    ReminderTime(hour: 8, minute: 0),
                    ReminderTime(hour: 20, minute: 0)
                ],
                start: start,
                windowEnd: end
            )
        )
        #expect(daily.requests.count == 14)
        #expect(
            daily.cadence == .daily(
                timesPerDay: 2,
                times: [
                    ReminderTime(hour: 8, minute: 0),
                    ReminderTime(hour: 20, minute: 0)
                ]
            )
        )

        let everyOther = try ReminderPlanner.plan(
            input(
                frequency: .everyOtherDay,
                times: [ReminderTime(hour: 8, minute: 0)],
                start: start,
                windowEnd: end
            )
        )
        #expect(everyOther.requests.count == 4)
        #expect(
            everyOther.requests.map {
                localDay($0.fireDate, timezone)
            } == [5, 7, 9, 11]
        )

        let weekly = try ReminderPlanner.plan(
            input(
                frequency: .weekly,
                weeklyCount: 2,
                times: [ReminderTime(hour: 8, minute: 0)],
                start: start,
                windowEnd: end
            )
        )
        #expect(weekly.requests.count == 2)
        #expect(
            weekly.requests.map {
                localDay($0.fireDate, timezone)
            } == [5, 8]
        )
        #expect(
            weekly.cadence == .weekly(
                timesPerWeek: 2,
                anchorDate: start,
                times: [ReminderTime(hour: 8, minute: 0)]
            )
        )
    }

    @Test("DST 缺失时刻按同一时区顺延且不做固定秒数推算")
    func daylightSavingGap() throws {
        let timezone = "America/New_York"
        let start = makeLocal(2025, 3, 8, 0, 0, timezone)
        let windowStart = makeLocal(2025, 3, 9, 0, 0, timezone)
        let windowEnd = makeLocal(2025, 3, 9, 23, 59, timezone)
        var value = input(
            frequency: .dailyOne,
            times: [ReminderTime(hour: 2, minute: 30)],
            start: start,
            windowEnd: windowEnd,
            timezone: timezone
        )
        value.windowStart = windowStart

        let plan = try ReminderPlanner.plan(value)
        let fire = try #require(plan.requests.first?.fireDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timezone))
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fire
        )
        #expect(components.year == 2025)
        #expect(components.month == 3)
        #expect(components.day == 9)
        #expect(components.hour == 3)
        #expect(components.minute == 0)
    }

    @Test("起止边界和滚动窗口严格限制系统请求数")
    func dateBoundsAndRollingLimit() throws {
        let timezone = "Asia/Shanghai"
        let start = makeLocal(2026, 2, 1, 12, 0, timezone)
        let end = makeLocal(2026, 2, 10, 23, 59, timezone)
        var value = input(
            frequency: .dailyOne,
            times: [ReminderTime(hour: 8, minute: 0)],
            start: start,
            windowEnd: end,
            timezone: timezone
        )
        value.endDate = makeLocal(2026, 2, 8, 9, 0, timezone)
        value.systemRequestLimit = 3

        let plan = try ReminderPlanner.plan(value)
        #expect(plan.requests.count == 3)
        #expect(plan.isTruncated)
        #expect(plan.requests.allSatisfy { $0.fireDate >= start })
        #expect(plan.requests.allSatisfy { $0.fireDate <= value.endDate! })
        #expect(localDay(plan.requests[0].fireDate, timezone) == 2)

        value.systemRequestLimit = 0
        let noRemainingCapacity = try ReminderPlanner.plan(value)
        #expect(noRemainingCapacity.requests.isEmpty)
        #expect(noRemainingCapacity.isTruncated)
    }

    @Test("拒绝超出 64 的预算和超长滚动窗口而不进入无界循环")
    func adversarialLimitsAreBounded() throws {
        let start = makeLocal(2026, 2, 1, 0, 0, "Asia/Shanghai")
        var hugeBudget = input(
            frequency: .dailyOne,
            times: [ReminderTime(hour: 8, minute: 0)],
            start: start,
            windowEnd: .distantFuture
        )
        hugeBudget.systemRequestLimit = .max
        #expect(throws: ReminderPlannerError.invalidSystemLimit) {
            try ReminderPlanner.plan(hugeBudget)
        }

        var hugeWindow = hugeBudget
        hugeWindow.systemRequestLimit = 64
        #expect(
            throws: ReminderPlannerError.windowTooLarge(
                maximumDays: ReminderPlanner.maximumRollingWindowDays
            )
        ) {
            try ReminderPlanner.plan(hugeWindow)
        }
    }

    @Test("同业务 revision reconcile 幂等，revision 替换移除旧请求")
    func reconciliationIsIdempotentByBusinessRevision() throws {
        let start = makeLocal(2026, 3, 1, 0, 0, "Asia/Shanghai")
        let first = try ReminderPlanner.plan(
            input(
                revision: 1,
                frequency: .dailyOne,
                times: [ReminderTime(hour: 8, minute: 0)],
                start: start,
                windowEnd: start.addingTimeInterval(3 * 86_400)
            )
        )
        let firstIDs = Set(first.requests.map(\.id))
        let idempotent = ReminderPlanner.reconcile(
            desired: first,
            existingIdentifiers: firstIDs
        )
        #expect(idempotent.schedule.isEmpty)
        #expect(idempotent.removeIdentifiers.isEmpty)
        #expect(Set(idempotent.unchangedIdentifiers) == firstIDs)

        let second = try ReminderPlanner.plan(
            input(
                revision: 2,
                frequency: .dailyOne,
                times: [ReminderTime(hour: 8, minute: 0)],
                start: start,
                windowEnd: start.addingTimeInterval(3 * 86_400)
            )
        )
        let replaced = ReminderPlanner.reconcile(
            desired: second,
            existingIdentifiers: firstIDs
        )
        #expect(replaced.schedule.count == second.requests.count)
        #expect(Set(replaced.removeIdentifiers) == firstIDs)
        #expect(replaced.unchangedIdentifiers.isEmpty)
    }

    @Test("每日频次严格匹配 1/2/3 个提醒时刻")
    func dailyFrequencyCountsAreStrict() throws {
        let start = makeLocal(2026, 4, 1, 0, 0, "Asia/Shanghai")
        #expect(
            throws: ReminderPlannerError.reminderTimeCount(
                expected: 2,
                actual: 1
            )
        ) {
            try ReminderPlanner.plan(
                input(
                    frequency: .dailyTwo,
                    times: [ReminderTime(hour: 8, minute: 0)],
                    start: start,
                    windowEnd: start.addingTimeInterval(86_400)
                )
            )
        }
        #expect(
            throws: ReminderPlannerError.reminderTimeCount(
                expected: 3,
                actual: 4
            )
        ) {
            try ReminderPlanner.plan(
                input(
                    frequency: .dailyThree,
                    times: [
                        ReminderTime(hour: 8, minute: 0),
                        ReminderTime(hour: 12, minute: 0),
                        ReminderTime(hour: 18, minute: 0),
                        ReminderTime(hour: 22, minute: 0)
                    ],
                    start: start,
                    windowEnd: start.addingTimeInterval(86_400)
                )
            )
        }
    }

    @Test("每周 N 次只允许一个每日时刻避免倍增")
    func weeklyRejectsMultipleClockTimes() throws {
        let start = makeLocal(2026, 4, 1, 0, 0, "Asia/Shanghai")
        #expect(
            throws: ReminderPlannerError.reminderTimeCount(
                expected: 1,
                actual: 2
            )
        ) {
            try ReminderPlanner.plan(
                input(
                    frequency: .weekly,
                    weeklyCount: 2,
                    times: [
                        ReminderTime(hour: 8, minute: 0),
                        ReminderTime(hour: 20, minute: 0)
                    ],
                    start: start,
                    windowEnd: start.addingTimeInterval(7 * 86_400)
                )
            )
        }
    }

    @Test("周频次 1 与 7 的请求数和语义一致")
    func weeklyBoundaryCounts() throws {
        let timezone = "Asia/Shanghai"
        let start = makeLocal(2026, 4, 6, 0, 0, timezone)
        let end = makeLocal(2026, 4, 12, 23, 59, timezone)
        let once = try ReminderPlanner.plan(
            input(
                frequency: .weekly,
                weeklyCount: 1,
                times: [ReminderTime(hour: 8, minute: 0)],
                start: start,
                windowEnd: end
            )
        )
        let everyDay = try ReminderPlanner.plan(
            input(
                frequency: .weekly,
                weeklyCount: 7,
                times: [ReminderTime(hour: 8, minute: 0)],
                start: start,
                windowEnd: end
            )
        )
        #expect(once.requests.count == 1)
        #expect(everyDay.requests.count == 7)
    }

    @Test("非每周频次拒绝残留 weeklyCount")
    func unexpectedWeeklyCountRejected() {
        let start = makeLocal(2026, 4, 1, 0, 0, "Asia/Shanghai")
        #expect(throws: ReminderPlannerError.unexpectedWeeklyCount) {
            try ReminderPlanner.plan(
                input(
                    frequency: .dailyOne,
                    weeklyCount: 2,
                    times: [ReminderTime(hour: 8, minute: 0)],
                    start: start,
                    windowEnd: start.addingTimeInterval(86_400)
                )
            )
        }
    }

    @Test("计划器拒绝 NaN 和无穷日期")
    func nonFiniteDatesRejected() {
        let valid = makeLocal(2026, 4, 1, 0, 0, "Asia/Shanghai")
        for value in [Double.nan, .infinity, -.infinity] {
            let invalid = Date(timeIntervalSince1970: value)
            #expect(throws: ReminderPlannerError.invalidDate) {
                try ReminderPlanner.plan(
                    input(
                        frequency: .dailyOne,
                        times: [ReminderTime(hour: 8, minute: 0)],
                        start: invalid,
                        windowEnd: valid
                    )
                )
            }
        }
    }

    @Test("滚动窗口允许恰好 366 个包含端点的自然日")
    func inclusive366DayWindowAccepted() throws {
        let timezone = "Asia/Shanghai"
        let start = makeLocal(2025, 1, 1, 0, 0, timezone)
        let end = try #require(addDays(365, to: start, timezone: timezone))
        let plan = try ReminderPlanner.plan(
            input(
                frequency: .weekly,
                weeklyCount: 1,
                times: [ReminderTime(hour: 8, minute: 0)],
                start: start,
                windowEnd: end,
                timezone: timezone
            )
        )
        #expect(!plan.requests.isEmpty)
        #expect(!plan.isTruncated)
    }

    @Test("滚动窗口拒绝 367 个包含端点的自然日")
    func inclusive367DayWindowRejected() throws {
        let timezone = "Asia/Shanghai"
        let start = makeLocal(2025, 1, 1, 0, 0, timezone)
        let end = try #require(addDays(366, to: start, timezone: timezone))
        #expect(
            throws: ReminderPlannerError.windowTooLarge(
                maximumDays: ReminderPlanner.maximumRollingWindowDays
            )
        ) {
            try ReminderPlanner.plan(
                input(
                    frequency: .weekly,
                    weeklyCount: 1,
                    times: [ReminderTime(hour: 8, minute: 0)],
                    start: start,
                    windowEnd: end,
                    timezone: timezone
                )
            )
        }
    }

    @Test("DST 重复时刻只生成第一次且不重复请求")
    func daylightSavingOverlapUsesFirstOccurrence() throws {
        let timezone = "America/New_York"
        let start = makeLocal(2025, 11, 2, 0, 0, timezone)
        let end = makeLocal(2025, 11, 2, 23, 59, timezone)
        let plan = try ReminderPlanner.plan(
            input(
                frequency: .dailyOne,
                times: [ReminderTime(hour: 1, minute: 30)],
                start: start,
                windowEnd: end,
                timezone: timezone
            )
        )
        let request = try #require(plan.requests.first)
        #expect(plan.requests.count == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timezone))
        let components = calendar.dateComponents(
            [.hour, .minute, .timeZone],
            from: request.fireDate
        )
        #expect(components.hour == 1)
        #expect(components.minute == 30)
        #expect(
            calendar.timeZone.secondsFromGMT(
                for: request.fireDate
            ) == -4 * 3_600
        )
    }

    @Test("系统总预算 64 精确截断且标记可续排")
    func exactSystemBudgetIsEnforced() throws {
        let timezone = "Asia/Shanghai"
        let start = makeLocal(2026, 5, 1, 0, 0, timezone)
        let end = makeLocal(2026, 5, 31, 23, 59, timezone)
        let plan = try ReminderPlanner.plan(
            input(
                frequency: .dailyThree,
                times: [
                    ReminderTime(hour: 8, minute: 0),
                    ReminderTime(hour: 13, minute: 0),
                    ReminderTime(hour: 20, minute: 0)
                ],
                start: start,
                windowEnd: end,
                timezone: timezone
            )
        )
        #expect(plan.requests.count == 64)
        #expect(plan.isTruncated)
        #expect(Set(plan.requests.map(\.id)).count == 64)
    }

    private func input(
        revision: Int = 1,
        frequency: FrequencyPreset,
        weeklyCount: Int? = nil,
        times: [ReminderTime],
        start: Date,
        windowEnd: Date,
        timezone: String = "Asia/Shanghai"
    ) -> ReminderPlanningInput {
        ReminderPlanningInput(
            reminderId: UUID(
                uuidString: "00000000-0000-0000-0000-000000000041"
            )!,
            businessRevision: revision,
            frequency: frequency,
            weeklyCount: weeklyCount,
            reminderTimes: times,
            startDate: start,
            timezoneIdentifier: timezone,
            windowStart: start,
            windowEnd: windowEnd,
            systemRequestLimit: 64
        )
    }

    private func makeLocal(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ timezone: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private func addDays(
        _ days: Int,
        to date: Date,
        timezone: String
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        return calendar.date(byAdding: .day, value: days, to: date)
    }

    private func localDay(
        _ date: Date,
        _ timezone: String
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        return calendar.component(.day, from: date)
    }
}
