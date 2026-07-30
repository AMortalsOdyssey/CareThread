import SwiftData
import Testing
@testable import CareThread

@MainActor
struct RecordOrderEditabilityTests {
    @Test("医嘱内容和完成状态使用同一 expectedRevision 保存")
    func orderContentAndCompletion_shareOneCASRevision() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        try context.save()
        let service = MedicalOrderService(context: context)
        let order = try service.createOrder(
            patientId: patient.id,
            content: "原医嘱"
        )
        var content = order.editableContent()
        content.content = " 人工修订医嘱 "
        content.isCompleted = true

        let revision = try service.editOrder(
            orderId: order.id,
            patientId: patient.id,
            content: content,
            changedFieldKeys: ["content", "isCompleted", "notActuallyChanged"],
            expectedRevision: 0
        )

        #expect(order.content == "人工修订医嘱")
        #expect(order.isCompleted)
        #expect(order.contentRevision == 1)
        #expect(Set(revision.changedFieldKeys) == ["content", "isCompleted"])
    }

    @Test("未改变医嘱不会制造空修订")
    func unchangedOrder_doesNotCreateRevision() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        try context.save()
        let service = MedicalOrderService(context: context)
        let order = try service.createOrder(
            patientId: patient.id,
            content: "原医嘱"
        )

        #expect(throws: MedicalOrderServiceError.noChanges) {
            try service.editOrder(
                orderId: order.id,
                patientId: patient.id,
                content: order.editableContent(),
                changedFieldKeys: ["content", "isCompleted"],
                expectedRevision: 0
            )
        }
        #expect(order.contentRevision == 0)
        #expect(
            try context.fetchCount(FetchDescriptor<ContentRevision>()) == 0
        )
    }
}
