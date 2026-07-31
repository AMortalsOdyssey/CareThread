import Foundation
import Testing
@testable import CareThread

private typealias Attachment = CareThread.Attachment

struct RecordListRowTests {
    @Test("记录卡片展示结论、异常、待确认、科室年龄来源和原件")
    func presentationIncludesDecisionFields() {
        let patientID = UUID()
        let recordID = UUID()
        let attachmentID = UUID()
        let attachment = Attachment(
            id: attachmentID,
            patientId: patientID,
            fileName:
                "members/\(patientID.uuidString)/records/\(recordID.uuidString)"
                + "/attachments/\(attachmentID.uuidString)/original.jpg",
            kind: .image,
            pageIndex: 0,
            recordId: recordID,
            integrityState: .verified
        )
        let record = MedicalRecord(
            id: recordID,
            patientId: patientID,
            type: .lab,
            title: "甲状腺功能五项",
            summary: "5 项指标，2 项异常：TSH 低，FT4 高。",
            eventDate: CTDate.make(2026, 3, 15),
            department: "内分泌科",
            ageAtEvent: 33,
            sourceType: .fixture,
            abnormalFlags: ["TSH 低"],
            reviewStatus: .pending,
            attachments: [attachment]
        )

        let value = RecordListRowPresentation(record: record)

        #expect(value.summary == "5 项指标，2 项异常：TSH 低，FT4 高。")
        #expect(value.showsAbnormalIndicator)
        #expect(value.statusTitle == "待确认")
        #expect(value.metadata == "内分泌科 · 33 岁 · 演示原件")
        #expect(value.hasAttachment)
    }

    @Test("已确认且无结论的记录不制造状态或空白结论")
    func confirmedEmptySummaryStaysCompact() {
        let record = MedicalRecord(
            patientId: UUID(),
            title: "随访记录",
            summary: "  \n ",
            eventDate: CTDate.make(2026, 7, 31),
            sourceType: .manual,
            reviewStatus: .confirmed
        )

        let value = RecordListRowPresentation(record: record)

        #expect(value.summary == nil)
        #expect(value.statusTitle == nil)
        #expect(value.metadata == "手动录入")
        #expect(!value.hasAttachment)
    }
}
