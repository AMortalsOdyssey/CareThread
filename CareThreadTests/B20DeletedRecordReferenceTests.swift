import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct B20DeletedRecordReferenceTests {
    @Test("B20 删除需带资料病历后保留可编辑的已删除占位")
    func deletedRecordBecomesStableTombstone() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "虚构检查报告",
            eventDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let followUp = FollowUp(
            patientId: patient.id,
            plannedDate: Date(timeIntervalSince1970: 2_000_000_000),
            items: ["虚构复查"],
            bringRecordIds: [record.id],
            reminderEnabled: false
        )
        context.insert(patient)
        context.insert(record)
        context.insert(followUp)
        try context.save()

        try RecordRepository(context: context).delete(record)
        let remainingRecords = try FollowUpRepository(
            context: context
        ).fetchRecords(patientID: patient.id)
        let references = FollowUpRecordReferenceResolver.resolve(
            ids: followUp.bringRecordIds,
            availableRecords: remainingRecords
        )

        #expect(references == [
            FollowUpRecordReference(
                id: record.id,
                availability: .deleted
            )
        ])
        #expect(followUp.bringRecordIds == [record.id])

        var edited = followUp.editableContent()
        edited.reason = "保留已删除资料的历史语义"
        edited.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
        _ = try MedicalOrderService(
            context: context,
            now: { Date(timeIntervalSince1970: 1_900_000_001) }
        ).editFollowUp(
            followUpId: followUp.id,
            patientId: patient.id,
            content: edited,
            changedFieldKeys: ["reason"],
            expectedRevision: 0
        )

        #expect(followUp.reason == "保留已删除资料的历史语义")
        #expect(followUp.bringRecordIds == [record.id])
    }
}
