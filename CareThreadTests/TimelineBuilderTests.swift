import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct TimelineBuilderTests {
    private let patientID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000010"
    )!
    private let otherPatientID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000020"
    )!
    private let now = CTDate.make(2026, 7, 31)

    @Test("多源事件按时间倒序且同刻记录优先于用药和复查")
    func mergesMultipleSourcesInStableClinicalOrder() {
        let instant = CTDate.make(2026, 3, 15)
        let record = makeRecord(
            id: fixedID(1),
            patientID: patientID,
            date: instant
        )
        let medication = Medication(
            id: fixedID(2),
            patientId: patientID,
            name: "虚构用药",
            doseValue: 1,
            doseUnit: "片",
            startDate: instant
        )
        let order = MedicalOrder(
            id: fixedID(3),
            patientId: patientID,
            content: "虚构医嘱",
            createdAt: instant
        )
        let followUp = FollowUp(
            id: fixedID(4),
            patientId: patientID,
            plannedDate: instant,
            items: ["虚构复查"],
            status: .completed,
            completedAt: instant
        )

        let events = build(
            records: [record],
            medications: [medication],
            orders: [order],
            followUps: [followUp]
        )

        #expect(
            events.map(\.kind) == [
                .medicalRecord,
                .medicationStarted,
                .medicalOrder,
                .followUpCompleted,
                .followUpDue
            ]
        )
    }

    @Test("同类型同刻事件以 UUID 稳定排序")
    func sameInstantUsesUUIDTieBreaker() {
        let instant = CTDate.make(2026, 1, 1)
        let laterID = fixedID(9)
        let earlierID = fixedID(8)
        let events = build(
            records: [
                makeRecord(
                    id: laterID,
                    patientID: patientID,
                    date: instant
                ),
                makeRecord(
                    id: earlierID,
                    patientID: patientID,
                    date: instant
                )
            ]
        )

        #expect(events.map(\.sourceID) == [earlierID, laterID])
    }

    @Test("剂量版本链生成单一调整事件且不重复停止事件")
    func doseAdjustmentSuppressesPairedStop() {
        let changeDate = CTDate.make(2026, 3, 15)
        let old = Medication(
            id: fixedID(10),
            patientId: patientID,
            name: "虚构药 A",
            doseValue: 100,
            doseUnit: "µg",
            startDate: CTDate.make(2025, 1, 1),
            endDate: changeDate,
            isLongTerm: false
        )
        let current = Medication(
            id: fixedID(11),
            patientId: patientID,
            name: "虚构药 A",
            doseValue: 75,
            doseUnit: "µg",
            startDate: changeDate,
            previousVersionId: old.id
        )

        let events = build(medications: [old, current])

        #expect(events.filter { $0.kind == .medicationAdjusted }.count == 1)
        #expect(events.filter { $0.kind == .medicationStopped }.isEmpty)
        #expect(
            events.first(where: { $0.kind == .medicationAdjusted })?.detail
                == "虚构药 A 100µg → 75µg"
        )
    }

    @Test("无后继版本的结束日期生成停止用药事件")
    func independentMedicationEndCreatesStop() {
        let medication = Medication(
            id: fixedID(12),
            patientId: patientID,
            name: "虚构药 B",
            doseValue: 1,
            doseUnit: "片",
            startDate: CTDate.make(2026, 1, 1),
            endDate: CTDate.make(2026, 2, 1),
            isLongTerm: false
        )

        let events = build(medications: [medication])

        #expect(events.map(\.kind).contains(.medicationStarted))
        #expect(events.map(\.kind).contains(.medicationStopped))
    }

    @Test("已完成复查保留计划与完成两个事实事件")
    func completedFollowUpCreatesCompletionEvent() {
        let followUp = FollowUp(
            id: fixedID(13),
            patientId: patientID,
            plannedDate: CTDate.make(2026, 2, 1),
            items: ["虚构项目"],
            status: .completed,
            completedAt: CTDate.make(2026, 2, 2)
        )

        let events = build(followUps: [followUp])

        #expect(events.map(\.kind) == [.followUpCompleted, .followUpDue])
        #expect(events.first?.title == Copy.Timeline.followUpCompleted)
    }

    @Test("过期状态只依赖注入的今天且不落库")
    func overdueUsesInjectedToday() {
        let followUp = FollowUp(
            id: fixedID(14),
            patientId: patientID,
            plannedDate: CTDate.make(2026, 7, 30),
            items: ["虚构项目"]
        )

        let overdue = build(
            followUps: [followUp],
            now: CTDate.make(2026, 7, 31)
        )
        let notOverdue = build(
            followUps: [followUp],
            now: CTDate.make(2026, 7, 30)
        )

        #expect(overdue.first?.isOverdue == true)
        #expect(notOverdue.first?.isOverdue == false)
        #expect(followUp.status == .pending)
    }

    @Test("仅异常只保留含异常事实的病历，不混入过期复查")
    func abnormalFilterKeepsOnlyAbnormalRecords() {
        let abnormal = makeRecord(
            id: fixedID(15),
            patientID: patientID,
            date: now,
            abnormalFlags: ["虚构指标偏高"]
        )
        let normal = makeRecord(
            id: fixedID(16),
            patientID: patientID,
            date: now
        )
        let overdue = FollowUp(
            id: fixedID(17),
            patientId: patientID,
            plannedDate: CTDate.make(2026, 7, 1),
            items: ["虚构复查"]
        )

        let filtered = TimelineBuilder.apply(
            .abnormal,
            to: build(
                records: [normal, abnormal],
                followUps: [overdue]
            )
        )

        #expect(filtered.count == 1)
        #expect(filtered.first?.sourceID == abnormal.id)
        #expect(filtered.first?.isAbnormal == true)
    }

    @Test("病历用药复查筛选互斥且医嘱归入复查")
    func categoryFiltersAreExclusive() {
        let record = makeRecord(
            id: fixedID(18),
            patientID: patientID,
            date: now
        )
        let medication = Medication(
            id: fixedID(19),
            patientId: patientID,
            name: "虚构药",
            startDate: now
        )
        let order = MedicalOrder(
            id: fixedID(20),
            patientId: patientID,
            content: "虚构医嘱",
            createdAt: now
        )
        let events = build(
            records: [record],
            medications: [medication],
            orders: [order]
        )

        #expect(TimelineBuilder.apply(.records, to: events).count == 1)
        #expect(TimelineBuilder.apply(.medications, to: events).count == 1)
        #expect(TimelineBuilder.apply(.followUps, to: events).count == 1)
    }

    @Test("Builder 在内存输入层仍执行成员隔离")
    func builderExcludesOtherMember() {
        let own = makeRecord(
            id: fixedID(21),
            patientID: patientID,
            date: now
        )
        let other = makeRecord(
            id: fixedID(22),
            patientID: otherPatientID,
            date: now
        )

        let events = build(records: [other, own])

        #expect(events.count == 1)
        #expect(events.first?.patientID == patientID)
    }

    @Test("Repository 谓词隔离成员且异常筛选不读取其他来源")
    func repositoryScopesToMember() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        context.insert(
            makeRecord(
                id: fixedID(23),
                patientID: patientID,
                date: now,
                abnormalFlags: ["虚构异常"]
            )
        )
        context.insert(
            makeRecord(
                id: fixedID(24),
                patientID: otherPatientID,
                date: now,
                abnormalFlags: ["其他成员虚构异常"]
            )
        )
        try context.save()

        let page = try TimelineRepository(context: context).page(
            patientID: patientID,
            filter: .abnormal,
            request: TimelinePageRequest(),
            now: now
        )

        #expect(page.events.count == 1)
        #expect(page.events.allSatisfy { $0.patientID == patientID })
    }

    @Test("前序正常记录不会饿死较早的异常筛选结果")
    func abnormalQueryScansBoundedSourceWindow() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        context.insert(
            makeRecord(
                id: fixedID(26),
                patientID: patientID,
                date: now.addingTimeInterval(-50 * 86_400),
                abnormalFlags: ["虚构异常"]
            )
        )
        for index in 0..<40 {
            context.insert(
                makeRecord(
                    id: UUID(),
                    patientID: patientID,
                    date: now.addingTimeInterval(
                        TimeInterval(-index * 86_400)
                    )
                )
            )
        }
        try context.save()

        let page = try TimelineRepository(context: context).page(
            patientID: patientID,
            filter: .abnormal,
            request: TimelinePageRequest(offset: 0, limit: 10),
            now: now
        )

        #expect(page.events.map(\.sourceID) == [fixedID(26)])
        #expect(!page.hasMore)
    }

    @Test("分页边界不重不漏且末页终止")
    func repositoryPaginationIsStable() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        for index in 0..<45 {
            context.insert(
                makeRecord(
                    id: UUID(),
                    patientID: patientID,
                    date: now.addingTimeInterval(
                        TimeInterval(-index * 86_400)
                    )
                )
            )
        }
        try context.save()
        let repository = TimelineRepository(context: context)

        let first = try repository.page(
            patientID: patientID,
            filter: .all,
            request: TimelinePageRequest(offset: 0, limit: 30),
            now: now
        )
        let second = try repository.page(
            patientID: patientID,
            filter: .all,
            request: TimelinePageRequest(offset: 30, limit: 30),
            now: now
        )

        #expect(first.events.count == 30)
        #expect(first.hasMore)
        #expect(second.events.count == 15)
        #expect(!second.hasMore)
        #expect(
            Set(first.events.map(\.id))
                .isDisjoint(with: Set(second.events.map(\.id)))
        )
    }

    @Test("页大小被安全上限约束且越界偏移返回终态")
    func repositoryBoundsRequests() throws {
        let request = TimelinePageRequest(offset: -5, limit: 10_000)
        #expect(request.offset == 0)
        #expect(request.limit == TimelineQueryPolicy.maximumPageSize)

        let container = try TestSupport.container()
        let page = try TimelineRepository(
            context: container.mainContext
        ).page(
            patientID: patientID,
            filter: .all,
            request: TimelinePageRequest(
                offset: TimelineQueryPolicy.maximumTimelineEvents
            ),
            now: now
        )
        #expect(page.events.isEmpty)
        #expect(!page.hasMore)
    }

    @Test("滚动超过阈值才显示回到最新入口")
    func returnToLatestThreshold() {
        #expect(
            !TimelineScrollPolicy.shouldShowReturnToLatest(
                visibleEventIndex: CT.Timeline.latestThreshold - 1
            )
        )
        #expect(
            TimelineScrollPolicy.shouldShowReturnToLatest(
                visibleEventIndex: CT.Timeline.latestThreshold
            )
        )
    }

    @Test("病历标题为空白时只在时间线展示层回退到类型名")
    func blankRecordTitleUsesDisplayFallback() {
        let record = MedicalRecord(
            id: fixedID(25),
            patientId: patientID,
            type: .pathology,
            title: "  \n",
            summary: "虚构摘要",
            eventDate: now,
            sourceType: .manual,
            reviewStatus: .needsInfo
        )

        let event = build(records: [record]).first

        #expect(event?.title == RecordType.pathology.displayName)
        #expect(record.title == "  \n")
    }

    @Test("复查事件的类型标签不重复标题中的复查安排")
    func followUpTypeUsesShortCategory() {
        #expect(
            Copy.Timeline.eventType(.followUpDue)
                == Copy.Timeline.filterFollowUps
        )
        #expect(
            Copy.Timeline.dayAndType(
                day: "15",
                type: Copy.Timeline.eventType(.followUpDue)
            ) == "15 日 · 复查"
        )
    }

    private func build(
        records: [MedicalRecord] = [],
        medications: [Medication] = [],
        orders: [MedicalOrder] = [],
        followUps: [FollowUp] = [],
        now: Date? = nil
    ) -> [TimelineEvent] {
        TimelineBuilder.build(
            patientID: patientID,
            records: records,
            medications: medications,
            orders: orders,
            followUps: followUps,
            now: now ?? self.now
        )
    }

    private func makeRecord(
        id: UUID,
        patientID: UUID,
        date: Date,
        abnormalFlags: [String] = []
    ) -> MedicalRecord {
        MedicalRecord(
            id: id,
            patientId: patientID,
            type: .lab,
            title: "虚构报告",
            summary: "虚构摘要",
            eventDate: date,
            sourceType: .manual,
            abnormalFlags: abnormalFlags,
            reviewStatus: .confirmed
        )
    }

    private func fixedID(_ suffix: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                suffix
            )
        )!
    }
}
