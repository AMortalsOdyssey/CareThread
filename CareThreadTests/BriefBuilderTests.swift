import Foundation
import Testing
@testable import CareThread

struct M7BriefBuilderTests {
    private let memberID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000701"
    )!
    private let otherMemberID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000702"
    )!
    private let now = CTDate.make(2026, 7, 31)

    @Test("摘要按固定章节顺序拼装全部要求内容")
    func buildsRequiredSectionsInFixedOrder() {
        let document = BriefBuilder.build(
            input: fullInput(),
            generatedAt: now
        )

        #expect(
            document.sections.map(\.id) == [
                .basicProfile,
                .currentIssues,
                .recentKeyResults,
                .currentMedications,
                .allergiesAndHistory,
                .pendingFollowUps,
                .selectedRecords,
                .questions
            ]
        )
        #expect(document.hasExportableContent)
        #expect(document.disclaimer.contains("不提供诊断"))
    }

    @Test("无内容章节自动隐藏且仅基本档案不可导出")
    func hidesEmptySectionsAndDisablesProfileOnlyExport() {
        let input = BriefInput(
            member: BriefMemberSnapshot(
                id: memberID,
                displayName: "虚构空成员",
                birthDate: nil,
                conditions: [],
                allergies: [],
                histories: []
            ),
            records: [],
            medications: [],
            followUps: []
        )
        let document = BriefBuilder.build(
            input: input,
            generatedAt: now
        )

        #expect(document.sections.map(\.id) == [.basicProfile])
        #expect(!document.hasExportableContent)
    }

    @Test("来源角标稳定并可回溯完整记录 UUID")
    func sourceNumbersAreStableAndTraceable() {
        let input = fullInput()
        let first = BriefBuilder.build(input: input, generatedAt: now)
        let second = BriefBuilder.build(
            input: BriefInput(
                member: input.member,
                records: input.records.reversed(),
                medications: input.medications,
                followUps: input.followUps,
                questions: input.questions
            ),
            generatedAt: now
        )

        #expect(first.sources == second.sources)
        #expect(first.sources.map(\.number) == [1, 2])
        #expect(first.sources.map(\.recordID) == [fixedID(2), fixedID(1)])
        #expect(BriefSource.marker(1) == "①")
        #expect(
            first.sections
                .flatMap(\.items)
                .filter { $0.sourceRecordID != nil }
                .allSatisfy { item in
                    first.sources.contains {
                        $0.recordID == item.sourceRecordID
                            && $0.number == item.sourceNumber
                    }
                }
        )
    }

    @Test("摘要严格按成员隔离所有实体")
    func isolatesMemberData() {
        var input = fullInput()
        input = BriefInput(
            member: input.member,
            records: input.records + [
                record(
                    id: fixedID(99),
                    patientID: otherMemberID,
                    date: CTDate.make(2026, 7, 30),
                    title: "不应出现的报告",
                    isAbnormal: true,
                    inBrief: true
                )
            ],
            medications: input.medications + [
                BriefMedicationSnapshot(
                    id: fixedID(98),
                    patientID: otherMemberID,
                    name: "不应出现的药",
                    doseValue: 9,
                    doseUnit: "片",
                    frequency: .dailyOne,
                    weeklyCount: nil,
                    startDate: CTDate.make(2026, 1, 1),
                    endDate: nil,
                    lifecycleStatus: .active
                )
            ],
            followUps: input.followUps,
            questions: input.questions
        )
        let document = BriefBuilder.build(input: input, generatedAt: now)
        let allText = document.sections.flatMap(\.items).map(\.text)
            .joined(separator: "\n")

        #expect(!allText.contains("不应出现"))
        #expect(!document.sources.map(\.recordID).contains(fixedID(99)))
    }

    @Test("编辑取舍可关闭章节并精确选择记录")
    func appliesSectionAndRecordSelection() {
        let selection = BriefSelection(
            enabledSections: [.basicProfile, .selectedRecords],
            selectedRecordIDs: [fixedID(1)]
        )
        let document = BriefBuilder.build(
            input: fullInput(),
            selection: selection,
            generatedAt: now
        )

        #expect(document.sections.map(\.id) == [.basicProfile, .selectedRecords])
        #expect(document.sources.map(\.recordID) == [fixedID(1)])
        #expect(
            document.sections
                .first(where: { $0.id == .selectedRecords })?
                .items.count == 1
        )
    }

    @Test("七档导出区间标签固定")
    func exposesAllRequiredRangePresets() {
        #expect(DateRangePreset.allCases.count == 7)
        #expect(
            DateRangePreset.allCases.map(\.displayName) == [
                "近 1 个月",
                "近半年",
                "近 1 年",
                "近 2 年",
                "近 5 年",
                "近 10 年",
                "全部"
            ]
        )
    }

    @Test("日历月边界含起始日且排除明日起点")
    func monthBoundaryIsCalendarBasedAndHalfOpen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let end = CTDate.make(2026, 3, 31, hour: 22)
        let interval = DateRangePreset.oneMonth.interval(
            endingAt: end,
            calendar: calendar
        )

        #expect(interval?.start == calendar.startOfDay(
            for: CTDate.make(2026, 2, 28)
        ))
        #expect(
            DateRangePreset.oneMonth.contains(
                CTDate.make(2026, 2, 28, hour: 0),
                endingAt: end,
                calendar: calendar
            )
        )
        #expect(
            !DateRangePreset.oneMonth.contains(
                CTDate.make(2026, 4, 1, hour: 0),
                endingAt: end,
                calendar: calendar
            )
        )
    }

    @Test("区间导出只含该成员范围内已确认记录")
    func exportPayloadFiltersRangeMemberAndReview() {
        var input = fullInput()
        input = BriefInput(
            member: input.member,
            records: input.records + [
                record(
                    id: fixedID(7),
                    patientID: memberID,
                    date: CTDate.make(2024, 1, 1),
                    title: "过早记录",
                    isAbnormal: true
                ),
                record(
                    id: fixedID(8),
                    patientID: memberID,
                    date: CTDate.make(2026, 7, 30),
                    title: "待确认记录",
                    isAbnormal: true,
                    status: .pending
                ),
                record(
                    id: fixedID(9),
                    patientID: otherMemberID,
                    date: CTDate.make(2026, 7, 30),
                    title: "其他成员",
                    isAbnormal: true
                )
            ],
            medications: input.medications,
            followUps: input.followUps,
            questions: input.questions
        )
        let payload = BriefBuilder.exportPayload(
            input: input,
            preset: .oneYear,
            generatedAt: now
        )

        #expect(payload.records.map(\.id) == [fixedID(2), fixedID(1)])
    }

    private func fullInput() -> BriefInput {
        BriefInput(
            member: member(),
            records: [
                record(
                    id: fixedID(1),
                    patientID: memberID,
                    date: CTDate.make(2026, 3, 15),
                    title: "虚构甲功五项",
                    summary: "TSH 高于参考范围",
                    isAbnormal: true,
                    inBrief: true,
                    symptom: "偶感心慌"
                ),
                record(
                    id: fixedID(2),
                    patientID: memberID,
                    date: CTDate.make(2026, 5, 20),
                    title: "虚构复查报告",
                    summary: "结构化复查结果",
                    isAbnormal: true,
                    inBrief: true
                )
            ],
            medications: [
                BriefMedicationSnapshot(
                    id: fixedID(3),
                    patientID: memberID,
                    name: "虚构药物",
                    doseValue: 75,
                    doseUnit: "µg",
                    frequency: .dailyOne,
                    weeklyCount: nil,
                    startDate: CTDate.make(2026, 3, 15),
                    endDate: nil,
                    lifecycleStatus: .active
                )
            ],
            followUps: [
                BriefFollowUpSnapshot(
                    id: fixedID(4),
                    patientID: memberID,
                    plannedDate: CTDate.make(2026, 9, 1),
                    items: ["虚构复查项目"],
                    reason: "按计划复查",
                    status: .pending
                )
            ],
            questions: ["这次检查需要带哪些旧资料？"]
        )
    }

    private func member() -> BriefMemberSnapshot {
        BriefMemberSnapshot(
            id: memberID,
            displayName: "虚构成员",
            birthDate: CTDate.make(1993, 1, 1),
            conditions: ["虚构慢病"],
            allergies: ["虚构药物过敏"],
            histories: [
                HistoryItem(year: 2024, text: "虚构手术史")
            ]
        )
    }

    private func record(
        id: UUID,
        patientID: UUID,
        date: Date,
        title: String,
        summary: String = "",
        isAbnormal: Bool,
        inBrief: Bool = false,
        status: ReviewStatus = .confirmed,
        symptom: String? = nil
    ) -> BriefRecordSnapshot {
        BriefRecordSnapshot(
            id: id,
            patientID: patientID,
            eventDate: date,
            title: title,
            summary: summary,
            type: .lab,
            reviewStatus: status,
            isInBrief: inBrief,
            abnormalFlags: isAbnormal ? ["虚构异常"] : [],
            structuredFields: [],
            measurements: [],
            tags: symptom.map {
                [BriefTagSnapshot(kind: .symptom, value: $0)]
            } ?? []
        )
    }

    private func fixedID(_ suffix: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                700 + suffix
            )
        )!
    }
}
