import Foundation
import SwiftData
import Testing
@testable import CareThread

struct LocalAskPresentationTests {
    @Test("标准版支持自由输入，大字版只显示四个固定问题")
    func modePoliciesStaySeparated() {
        #expect(LocalAskPresentationPolicy.showsFreeText(in: .standard))
        #expect(!LocalAskPresentationPolicy.showsFreeText(in: .elder))
        #expect(LocalAskPresentationPolicy.presets(in: .elder).count == 4)
        #expect(LocalAskPresentationPolicy.presets(in: .standard).count == 4)
    }

    @Test("四个问题文案与任务书逐字一致且顺序稳定")
    func presetQuestionsMatchTheProductContract() {
        #expect(
            LocalAskPreset.allCases.map(\.title) == [
                "我在吃什么药？",
                "下次什么时候复查？",
                "上次检查结果怎么样？",
                "最近去过哪些医院？"
            ]
        )
        #expect(Set(LocalAskPreset.allCases.map(\.systemImage)).count == 4)
    }

    @Test("一期事实响应保留概述插槽但不填入生成内容")
    func phaseOneOverviewSlotRemainsEmpty() {
        let response = LocalAskResponse(
            intents: [.freeText],
            timeScope: .allTime,
            metricFacts: [],
            medicationFacts: [],
            followUpFacts: [],
            hospitalFacts: [],
            recordHits: [],
            factualOverview: nil
        )

        #expect(response.factualOverview == nil)
        #expect(response.generatedDisplayText == [
            LocalAskResponse.factualDisclaimer,
            "查找范围：全部时间"
        ].joined(separator: "\n"))
    }

    @Test("指标异常状态只复述原记录标记")
    func abnormalLabelsAreFactual() {
        #expect(LocalAskFactPresentation.abnormalLabel(.none) == nil)
        #expect(LocalAskFactPresentation.abnormalLabel(.low) == "↓ 原记录标记：偏低")
        #expect(LocalAskFactPresentation.abnormalLabel(.high) == "↑ 原记录标记：偏高")
        #expect(LocalAskFactPresentation.abnormalLabel(.positive) == "● 原记录标记：阳性")
    }

    @Test("复查倒计时按上海日历日显示今天未来与过期")
    func followUpCountdownUsesCalendarDays() {
        let now = CTDate.make(2026, 7, 31, hour: 12)
        #expect(LocalAskFactPresentation.followUpCountdown(
            plannedDate: CTDate.make(2026, 7, 31),
            status: .pending,
            now: now
        ) == "今天")
        #expect(LocalAskFactPresentation.followUpCountdown(
            plannedDate: CTDate.make(2026, 8, 2),
            status: .pending,
            now: now
        ) == "还有 2 天")
        #expect(LocalAskFactPresentation.followUpCountdown(
            plannedDate: CTDate.make(2026, 7, 29),
            status: .pending,
            now: now
        ) == "已过期 2 天")
        #expect(LocalAskFactPresentation.followUpCountdown(
            plannedDate: CTDate.make(2026, 7, 29),
            status: .completed,
            now: now
        ) == "已完成")
    }

    @Test("来源存在时打开来源记录，缺失或悬空时精确回退到用药")
    func medicationSourceRouteFallsBackForMissingAndDanglingSources() {
        let sourceID = UUID()
        let medicationID = UUID()
        let missingID = UUID()

        #expect(LocalAskSourceRoute.medication(
            sourceRecordID: sourceID,
            medicationID: medicationID,
            availableRecordIDs: [sourceID]
        ) == .record(sourceID))
        #expect(LocalAskSourceRoute.medication(
            sourceRecordID: nil,
            medicationID: medicationID,
            availableRecordIDs: [sourceID]
        ) == .medication(medicationID))
        #expect(LocalAskSourceRoute.medication(
            sourceRecordID: missingID,
            medicationID: medicationID,
            availableRecordIDs: [sourceID]
        ) == .medication(medicationID))
    }

    @Test("来源存在时打开来源记录，缺失或悬空时精确回退到复查")
    func followUpSourceRouteFallsBackForMissingAndDanglingSources() {
        let sourceID = UUID()
        let followUpID = UUID()
        let missingID = UUID()

        #expect(LocalAskSourceRoute.followUp(
            sourceRecordID: sourceID,
            followUpID: followUpID,
            availableRecordIDs: [sourceID]
        ) == .record(sourceID))
        #expect(LocalAskSourceRoute.followUp(
            sourceRecordID: nil,
            followUpID: followUpID,
            availableRecordIDs: [sourceID]
        ) == .followUp(followUpID))
        #expect(LocalAskSourceRoute.followUp(
            sourceRecordID: missingID,
            followUpID: followUpID,
            availableRecordIDs: [sourceID]
        ) == .followUp(followUpID))
    }

    @MainActor
    @Test("精确回跳不受五百条列表上限影响")
    func exactInitialRoutesBypassListFetchLimit() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构大体量成员")
        context.insert(patient)
        let patientID = patient.id

        let medicationID = UUID()
        let targetMedication = Medication(
            id: medicationID,
            patientId: patientID,
            name: "虚构第 501 条目标用药",
            doseValue: 75,
            doseUnit: "µg",
            startDate: CTDate.make(2020, 1, 1),
            createdAt: CTDate.make(2020, 1, 1)
        )
        context.insert(targetMedication)
        for index in 0..<500 {
            context.insert(Medication(
                patientId: patientID,
                name: "虚构用药 \(index)",
                startDate: CTDate.make(2021, 1, 1)
                    .addingTimeInterval(Double(index))
            ))
        }

        let followUpID = UUID()
        let targetFollowUp = FollowUp(
            id: followUpID,
            patientId: patientID,
            plannedDate: CTDate.make(2035, 1, 1),
            items: ["虚构第 501 条目标复查"]
        )
        context.insert(targetFollowUp)
        for index in 0..<500 {
            context.insert(FollowUp(
                patientId: patientID,
                plannedDate: CTDate.make(2026, 1, 1)
                    .addingTimeInterval(Double(index)),
                items: ["虚构复查 \(index)"]
            ))
        }
        try context.save()

        var limitedMedications = FetchDescriptor<Medication>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        limitedMedications.fetchLimit = M4M5QueryLimit.standard
        let visibleMedications = try context.fetch(limitedMedications)
        #expect(!visibleMedications.contains {
            $0.id == medicationID
        })
        #expect(
            try M4M5InitialRouteLookup.medication(
                context: context,
                patientID: patientID,
                medicationID: medicationID
            )?.id == medicationID
        )

        let visibleFollowUps = try FollowUpRepository(
            context: context
        ).fetch(patientID: patientID)
        #expect(!visibleFollowUps.contains {
            $0.id == followUpID
        })
        #expect(
            try M4M5InitialRouteLookup.followUp(
                context: context,
                patientID: patientID,
                followUpID: followUpID
            )?.id == followUpID
        )
    }

    @Test("固定生成文案与响应生成文案不含医疗建议词")
    func fixedGeneratedCopyContainsNoMedicalAdviceTerms() {
        let response = LocalAskResponse(
            intents: [.freeText],
            timeScope: .allTime,
            metricFacts: [],
            medicationFacts: [],
            followUpFacts: [],
            hospitalFacts: [],
            recordHits: [],
            factualOverview: nil
        )
        let forbidden = ["应该", "建议", "说明", "可能是", "需要"]
        let generated = ([response.generatedDisplayText]
            + LocalAskGeneratedCopy.fixedUIStrings).joined(separator: "\n")
        #expect(forbidden.allSatisfy { !generated.contains($0) })
    }

    @MainActor
    @Test("真实编辑来源保存并返回后 Ask 只显示新值")
    func savedMedicationEditRefreshesActiveAskResponse() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构刷新成员")
        context.insert(patient)
        let patientID = patient.id
        let original = Medication(
            patientId: patientID,
            name: "虚构左甲状腺素钠片",
            doseValue: 50,
            doseUnit: "µg",
            startDate: CTDate.make(2026, 1, 1)
        )
        context.insert(original)
        try context.save()

        var coordinator = LocalAskRefreshCoordinator()
        let query = "我在吃什么药？"
        let now = CTDate.make(2026, 8, 1)
        let before = try await coordinator.rebuild(
            memberID: patientID,
            activeQuery: query,
            records: [],
            medications: [original],
            followUps: [],
            now: now
        )
        #expect(before.response?.medicationFacts.map(\.doseValue) == [50])

        _ = try MedicationService(
            context: context,
            now: { now }
        ).adjustDose(
            medicationId: original.id,
            patientId: patientID,
            expectedRevision: original.contentRevision,
            doseValue: 75,
            doseUnit: "µg",
            effectiveAt: CTDate.make(2026, 7, 1)
        )
        coordinator.sourceDidSave()

        let medications = try context.fetch(FetchDescriptor<Medication>(
            predicate: #Predicate { $0.patientId == patientID }
        ))
        let after = try await coordinator.rebuild(
            memberID: patientID,
            activeQuery: query,
            records: [],
            medications: medications,
            followUps: [],
            now: now
        )
        let refreshedDoses = after.response?.medicationFacts
            .compactMap(\.doseValue)

        #expect(coordinator.sourceRevision == 1)
        #expect(refreshedDoses == [75])
        #expect(refreshedDoses?.contains(50) == false)
    }
}
