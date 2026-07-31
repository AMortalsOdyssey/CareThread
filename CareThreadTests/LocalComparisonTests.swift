import Foundation
import Testing
@testable import CareThread

struct M7LocalComparisonTests {
    private let memberID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000751"
    )!
    private let otherID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000752"
    )!
    private let earlier = ComparisonPeriod(
        label: "过去",
        start: CTDate.make(2025, 1, 1),
        end: CTDate.make(2026, 1, 1)
    )
    private let later = ComparisonPeriod(
        label: "最近",
        start: CTDate.make(2026, 1, 1),
        end: CTDate.make(2027, 1, 1)
    )

    @Test("同名同单位指标比较最新值并计算差值")
    func comparesOnlyMatchingMetricAndUsesLatestValue() {
        let records = [
            record(id: 1, member: memberID, date: CTDate.make(2025, 2, 1), value: 1),
            record(id: 2, member: memberID, date: CTDate.make(2025, 9, 1), value: 2),
            record(id: 3, member: memberID, date: CTDate.make(2026, 5, 1), value: 5)
        ]
        let report = build(records)

        #expect(report.metrics.count == 1)
        #expect(report.metrics.first?.earlier.value == 2)
        #expect(report.metrics.first?.later.value == 5)
        #expect(report.metrics.first?.delta == 3)
        #expect(report.insufficientDataMessage == nil)
    }

    @Test("同名但单位不同绝不混算")
    func doesNotMixDifferentUnits() {
        let records = [
            record(
                id: 4,
                member: memberID,
                date: CTDate.make(2025, 5, 1),
                value: 1,
                unit: "mg/L"
            ),
            record(
                id: 5,
                member: memberID,
                date: CTDate.make(2026, 5, 1),
                value: 100,
                unit: "µg/L"
            )
        ]
        let report = build(records)

        #expect(report.metrics.isEmpty)
        #expect(report.unavailableMetricNames.count == 2)
        #expect(report.insufficientDataMessage?.contains("同名且同单位") == true)
    }

    @Test("对比严格排除其他成员数据")
    func isolatesMemberFacts() {
        let records = [
            record(id: 6, member: memberID, date: CTDate.make(2025, 5, 1), value: 1),
            record(id: 7, member: memberID, date: CTDate.make(2026, 5, 1), value: 2),
            record(id: 8, member: otherID, date: CTDate.make(2026, 5, 1), value: 99)
        ]
        let report = build(records)

        #expect(report.metrics.first?.later.value == 2)
        #expect(report.laterFacts.recordCount == 1)
    }

    @Test("两时段空数据明确提示样本不足")
    func emptyPeriodsExplainInsufficientData() {
        let report = build([])

        #expect(report.metrics.isEmpty)
        #expect(report.insufficientDataMessage?.contains("两个时段") == true)
        #expect(!report.hasAnyFacts)
        #expect(report.disclaimer.contains("不提供诊断"))
    }

    @Test("记录数异常数症状数和文字变化只陈述事实")
    func comparesFactualCountsAndTextChanges() {
        let first = record(
            id: 9,
            member: memberID,
            date: CTDate.make(2025, 5, 1),
            value: 1,
            summary: "过去记录的虚构情况",
            symptom: "心慌",
            abnormal: true
        )
        let second = record(
            id: 10,
            member: memberID,
            date: CTDate.make(2026, 5, 1),
            value: 2,
            summary: "最近记录的虚构情况",
            symptom: "心慌",
            abnormal: false
        )
        let report = build([first, second])

        #expect(report.earlierFacts.abnormalRecordCount == 1)
        #expect(report.laterFacts.abnormalRecordCount == 0)
        #expect(report.earlierFacts.symptomCounts["心慌"] == 1)
        #expect(report.addedTextFacts == ["最近记录的虚构情况"])
        #expect(report.removedTextFacts == ["过去记录的虚构情况"])
    }

    @Test("文本值指标不会伪装成数值变化")
    func textualMeasurementsAreNotComparedAsNumbers() {
        var first = record(
            id: 11,
            member: memberID,
            date: CTDate.make(2025, 5, 1),
            value: nil
        )
        first = replacingMeasurements(
            in: first,
            with: [
                BriefMeasurementSnapshot(
                    name: "虚构定性项目",
                    numericValue: nil,
                    textualValue: "阴性",
                    unit: "",
                    abnormalState: .none
                )
            ]
        )
        let report = build([first])

        #expect(report.metrics.isEmpty)
        #expect(report.insufficientDataMessage != nil)
    }

    private func build(
        _ records: [BriefRecordSnapshot]
    ) -> LocalComparisonReport {
        LocalComparisonBuilder.build(
            memberID: memberID,
            records: records,
            earlierPeriod: earlier,
            laterPeriod: later
        )
    }

    private func record(
        id: Int,
        member: UUID,
        date: Date,
        value: Double?,
        unit: String = "mIU/L",
        summary: String = "",
        symptom: String? = nil,
        abnormal: Bool = false
    ) -> BriefRecordSnapshot {
        BriefRecordSnapshot(
            id: fixedID(id),
            patientID: member,
            eventDate: date,
            title: "虚构指标记录",
            summary: summary,
            type: .lab,
            reviewStatus: .confirmed,
            isInBrief: false,
            abnormalFlags: abnormal ? ["虚构异常"] : [],
            structuredFields: [],
            measurements: [
                BriefMeasurementSnapshot(
                    name: "TSH",
                    numericValue: value,
                    textualValue: nil,
                    unit: unit,
                    abnormalState: abnormal ? .high : .none
                )
            ],
            tags: symptom.map {
                [BriefTagSnapshot(kind: .symptom, value: $0)]
            } ?? []
        )
    }

    private func replacingMeasurements(
        in record: BriefRecordSnapshot,
        with measurements: [BriefMeasurementSnapshot]
    ) -> BriefRecordSnapshot {
        BriefRecordSnapshot(
            id: record.id,
            patientID: record.patientID,
            eventDate: record.eventDate,
            title: record.title,
            summary: record.summary,
            type: record.type,
            reviewStatus: record.reviewStatus,
            isInBrief: record.isInBrief,
            abnormalFlags: record.abnormalFlags,
            structuredFields: record.structuredFields,
            measurements: measurements,
            tags: record.tags
        )
    }

    private func fixedID(_ suffix: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                750 + suffix
            )
        )!
    }
}
