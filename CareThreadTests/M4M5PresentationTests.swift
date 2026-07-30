import Foundation
import SwiftData
import Testing
@testable import CareThread

struct M4M5PresentationTests {
    private let now = CTDate.make(2026, 7, 30)

    @Test("上午问候由注入时间决定")
    func morningGreeting() {
        #expect(
            M4M5CalendarMath.greeting(
                at: CTDate.make(2026, 7, 30, hour: 8)
            ) == Copy.Home.morningGreeting
        )
    }

    @Test("下午问候由注入时间决定")
    func afternoonGreeting() {
        #expect(
            M4M5CalendarMath.greeting(
                at: CTDate.make(2026, 7, 30, hour: 14)
            ) == Copy.Home.afternoonGreeting
        )
    }

    @Test("晚上问候由注入时间决定")
    func eveningGreeting() {
        #expect(
            M4M5CalendarMath.greeting(
                at: CTDate.make(2026, 7, 30, hour: 20)
            ) == Copy.Home.eveningGreeting
        )
    }

    @Test("用药表单缺少药名禁止保存")
    func medicationMissingName() {
        var state = MedicationFormState(now: now)
        state.doseText = "75"
        #expect(state.validation == .missingName)
        #expect(!state.canSave)
    }

    @Test("用药表单拒绝零剂量")
    func medicationZeroDose() {
        var state = validMedicationState()
        state.doseText = "0"
        #expect(state.validation == .invalidDose)
    }

    @Test("B13 用药结束日早于开始日行内报错")
    func medicationEndBeforeStart() {
        var state = validMedicationState()
        state.isLongTerm = false
        state.endDate = now.addingTimeInterval(-86_400)
        #expect(state.validation == .endBeforeStart)
        #expect(state.validation.message == Copy.Medication.endBeforeStart)
    }

    @Test("每周频次只接受 1 到 7 次")
    func medicationWeeklyBoundary() {
        var state = validMedicationState()
        state.changeFrequency(to: .weekly)
        state.weeklyCount = 0
        #expect(state.validation == .invalidWeeklyCount)
        state.weeklyCount = 7
        #expect(state.validation == .valid)
    }

    @Test("按需用药自动关闭提醒且没有时刻")
    func medicationAsNeededDisablesReminder() {
        var state = validMedicationState()
        state.setReminderEnabled(true)
        state.changeFrequency(to: .asNeeded)
        #expect(!state.reminderEnabled)
        #expect(state.reminderTimes.isEmpty)
    }

    @Test("每日一次切换生成 08:00 可编辑建议")
    func medicationDailyOneSuggestion() {
        var state = validMedicationState()
        state.changeFrequency(to: .dailyOne)
        #expect(
            state.reminderTimes == [ReminderTime(hour: 8, minute: 0)]
        )
    }

    @Test("每日两次切换生成 08:00 和 20:00")
    func medicationDailyTwoSuggestion() {
        var state = validMedicationState()
        state.changeFrequency(to: .dailyTwo)
        #expect(
            state.reminderTimes == [
                ReminderTime(hour: 8, minute: 0),
                ReminderTime(hour: 20, minute: 0)
            ]
        )
    }

    @Test("每日三次切换生成 08:00、13:00 和 20:00")
    func medicationDailyThreeSuggestion() {
        var state = validMedicationState()
        state.changeFrequency(to: .dailyThree)
        #expect(
            state.reminderTimes == [
                ReminderTime(hour: 8, minute: 0),
                ReminderTime(hour: 13, minute: 0),
                ReminderTime(hour: 20, minute: 0)
            ]
        )
    }

    @Test("用药草稿保留余量与补药提醒")
    func medicationDraftRefillMapping() throws {
        var state = validMedicationState()
        state.remainingQuantityText = "12.5"
        state.refillReminderEnabled = true
        state.refillReminderAt = now.addingTimeInterval(86_400)
        let draft = try #require(state.draft(patientID: UUID()))
        #expect(draft.remainingQuantity == 12.5)
        #expect(draft.refillReminderAt == state.refillReminderAt)
    }

    @Test("医嘱 3 个月后复查可预填日期和项目")
    func orderThreeMonthPrefill() {
        let value = OrderFollowUpPrefill.make(
            orderText: "3 个月后复查甲状腺功能",
            now: now,
            calendar: CTDate.calendar
        )
        #expect(value.item == "甲状腺功能")
        #expect(
            CTDate.calendar.dateComponents(
                [.month],
                from: now,
                to: value.plannedDate
            ).month == 3
        )
    }

    @Test("无法解析期限的医嘱采用三个月可编辑默认值")
    func orderFallbackPrefill() {
        let value = OrderFollowUpPrefill.make(
            orderText: "按时复查甲功",
            now: now,
            calendar: CTDate.calendar
        )
        #expect(value.item == "甲功")
        #expect(
            CTDate.calendar.dateComponents(
                [.month],
                from: now,
                to: value.plannedDate
            ).month == 3
        )
    }

    @Test("复查表单必须有项目")
    func followUpRequiresItem() {
        let state = FollowUpFormState(now: now)
        #expect(state.validation(now: now) == .missingItems)
    }

    @Test("待办复查不能保存到过去")
    func followUpRejectsPastDate() {
        var state = FollowUpFormState(now: now)
        state.itemsText = "甲功"
        state.plannedDate = now.addingTimeInterval(-86_400)
        #expect(state.validation(now: now) == .dateInPast)
    }

    @Test("复查项目支持中英文逗号和顿号拆分")
    func followUpItemParsing() {
        var state = FollowUpFormState(now: now)
        state.itemsText = "甲功、颈部超声, 血常规，肝功能"
        #expect(state.items == ["甲功", "颈部超声", "血常规", "肝功能"])
    }

    @Test("B14 过期复查固定进入危险分组")
    func followUpOverdueGrouping() {
        let patientID = UUID()
        let overdue = FollowUp(
            patientId: patientID,
            plannedDate: now.addingTimeInterval(-86_400),
            items: ["甲功"]
        )
        let sections = FollowUpSections.make(
            followUps: [overdue],
            now: now,
            calendar: CTDate.calendar
        )
        #expect(sections.overdue == [overdue.id])
    }

    @Test("未来 30 天边界归入最近分组")
    func followUpThirtyDayBoundary() {
        let patientID = UUID()
        let boundary = CTDate.calendar.date(
            byAdding: .day,
            value: 30,
            to: now
        )!
        let followUp = FollowUp(
            patientId: patientID,
            plannedDate: boundary,
            items: ["甲功"]
        )
        let sections = FollowUpSections.make(
            followUps: [followUp],
            now: now,
            calendar: CTDate.calendar
        )
        #expect(sections.nextThirtyDays == [followUp.id])
    }

    @Test("已完成复查不再进入待办分组")
    func completedFollowUpGrouping() {
        let followUp = FollowUp(
            patientId: UUID(),
            plannedDate: now,
            items: ["甲功"],
            status: .completed,
            completedAt: now
        )
        let sections = FollowUpSections.make(
            followUps: [followUp],
            now: now
        )
        #expect(sections.completed == [followUp.id])
        #expect(sections.overdue.isEmpty)
        #expect(sections.nextThirtyDays.isEmpty)
    }

    @MainActor
    @Test("首页快照严格按成员隔离")
    func homeSnapshotMemberScope() throws {
        let container = try TestSupport.container()
        let first = Patient(name: "甲")
        let second = Patient(name: "乙")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        container.mainContext.insert(
            Medication(
                patientId: first.id,
                name: "虚构药",
                doseValue: 1,
                doseUnit: "片",
                startDate: now
            )
        )
        try container.mainContext.save()

        let firstLoaded = try HomeDashboardLoader(
            context: container.mainContext,
            now: { self.now }
        ).load(patientID: first.id)
        let secondLoaded = try HomeDashboardLoader(
            context: container.mainContext,
            now: { self.now }
        ).load(patientID: second.id)
        let firstValue = try #require(firstLoaded)
        let secondValue = try #require(secondLoaded)
        #expect(firstValue.medications.count == 1)
        #expect(secondValue.medications.isEmpty)
    }

    @MainActor
    @Test("复查完成经 CAS 写入状态和完成时间")
    func followUpCompletionPersists() throws {
        let container = try TestSupport.container()
        let patient = Patient(name: "虚构成员")
        let followUp = FollowUp(
            patientId: patient.id,
            plannedDate: now,
            items: ["甲功"]
        )
        container.mainContext.insert(patient)
        container.mainContext.insert(followUp)
        try container.mainContext.save()

        try FollowUpRepository(
            context: container.mainContext,
            now: { self.now }
        ).completeOnly(followUp)
        #expect(followUp.status == .completed)
        #expect(followUp.completedAt == now)
        #expect(!followUp.reminderEnabled)
    }

    private func validMedicationState() -> MedicationFormState {
        var state = MedicationFormState(now: now)
        state.name = "虚构药"
        state.doseText = "75"
        state.doseUnit = "µg"
        return state
    }
}
