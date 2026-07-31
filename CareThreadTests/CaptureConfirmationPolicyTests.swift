import Foundation
import Testing
@testable import CareThread

struct M3ConfirmationPolicyTests {
    @Test("空标题保持空值、展示回退类型名并标记需补充")
    func emptyTitle_keepsSemanticAndNeedsInfo() {
        let eventDate = CTDate.make(2026, 7, 30)
        let record = MedicalRecord(
            patientId: UUID(),
            type: .lab,
            title: "  ",
            eventDate: eventDate,
            reviewStatus: M3ConfirmationPolicy.reviewStatus(
                title: "  ",
                eventDate: eventDate,
                now: eventDate
            )
        )

        #expect(record.title == "  ")
        #expect(record.displayTitle == RecordType.lab.displayName)
        #expect(record.reviewStatus == .needsInfo)
    }

    @Test("未来日期允许保存但状态保持待核对")
    func futureDate_isPending() {
        let today = CTDate.make(2026, 7, 30)
        let tomorrow = CTDate.make(2026, 7, 31)

        #expect(M3ConfirmationPolicy.isFutureEventDate(tomorrow, now: today))
        #expect(
            M3ConfirmationPolicy.reviewStatus(
                title: "虚构复查记录",
                eventDate: tomorrow,
                now: today
            ) == .pending
        )
    }

    @Test("非未来且标题完整可确认为已确认")
    func completeCurrentRecord_isConfirmed() {
        let today = CTDate.make(2026, 7, 30)

        #expect(
            M3ConfirmationPolicy.reviewStatus(
                title: "虚构检验报告",
                eventDate: today,
                now: today
            ) == .confirmed
        )
    }

    @Test("生日缺失时手填年龄只接受 0 到 130")
    func manualAge_acceptsBoundaryAndRejectsOutside() {
        #expect(M3ConfirmationPolicy.manualAge(from: "0") == 0)
        #expect(M3ConfirmationPolicy.manualAge(from: "130") == 130)
        #expect(M3ConfirmationPolicy.manualAge(from: "131") == nil)
        #expect(M3ConfirmationPolicy.manualAge(from: "-1") == nil)
        #expect(M3ConfirmationPolicy.manualAge(from: "33.5") == nil)
        #expect(M3ConfirmationPolicy.isManualAgeValid(""))
    }

    @Test("检验值留空不会被零值替代")
    func blankLabValue_isNotMaterializedAsZero() {
        let draft = M3LabItemDraft(
            name: "虚构指标",
            valueText: "",
            unit: "mmol/L",
            refLowText: "1",
            refHighText: "3",
            flag: .none
        )

        #expect(draft.hasBlankValue)
        #expect(draft.materialized() == nil)
    }

    @Test("检验项逐字段编辑后完整转换")
    func validLabDraft_materializesAllFields() {
        let draft = M3LabItemDraft(
            name: " 虚构指标 ",
            valueText: "2,5",
            unit: " mmol/L ",
            refLowText: "1.2",
            refHighText: "3.8",
            flag: .high,
            confidence: .low
        )

        let item = draft.materialized()
        #expect(item?.name == "虚构指标")
        #expect(item?.value == 2.5)
        #expect(item?.unit == "mmol/L")
        #expect(item?.refLow == 1.2)
        #expect(item?.refHigh == 3.8)
        #expect(item?.flag == .high)
        #expect(item?.confidence == .low)
    }

    @Test("参考下限高于上限时拒绝转换")
    func invertedReferenceRange_isRejected() {
        let draft = M3LabItemDraft(
            name: "虚构指标",
            valueText: "2",
            refLowText: "5",
            refHighText: "3"
        )

        #expect(draft.hasValidationError)
        #expect(draft.materialized() == nil)
    }
}
