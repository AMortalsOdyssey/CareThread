import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct M4MedicalOrderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("同成员医嘱显式生成一次复查且完全相同重试幂等")
    func orderToFollowUpIsIdempotent() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        try context.save()
        let service = MedicalOrderService(
            context: context,
            now: { self.now }
        )
        let order = try service.createOrder(
            patientId: patient.id,
            content: "三个月后复查（虚构）"
        )
        let planned = now.addingTimeInterval(90 * 86_400)

        let first = try service.createFollowUp(
            fromOrderId: order.id,
            patientId: patient.id,
            expectedOrderRevision: 0,
            plannedDate: planned,
            items: ["虚构检查 A"],
            reason: "遵医嘱"
        )
        let retry = try service.createFollowUp(
            fromOrderId: order.id,
            patientId: patient.id,
            expectedOrderRevision: 0,
            plannedDate: planned,
            items: ["虚构检查 A"],
            reason: "遵医嘱"
        )

        #expect(first.id == retry.id)
        #expect(first.sourceOrderId == order.id)
        #expect(order.generatedFollowUpId == first.id)
        #expect(try context.fetchCount(FetchDescriptor<FollowUp>()) == 1)
    }

    @Test("同一 sourceOrderId 的冲突重复、跨成员和过去日期均拒绝")
    func duplicateCrossScopeAndInvalidDateRejected() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = Patient(name: "甲")
        let second = Patient(name: "乙")
        context.insert(first)
        context.insert(second)
        try context.save()
        let service = MedicalOrderService(
            context: context,
            now: { self.now }
        )
        let order = try service.createOrder(
            patientId: first.id,
            content: "虚构医嘱"
        )
        let planned = now.addingTimeInterval(86_400)
        _ = try service.createFollowUp(
            fromOrderId: order.id,
            patientId: first.id,
            expectedOrderRevision: 0,
            plannedDate: planned,
            items: ["虚构检查 A"]
        )

        #expect(throws: MedicalOrderServiceError.duplicateOrderFollowUp) {
            try service.createFollowUp(
                fromOrderId: order.id,
                patientId: first.id,
                expectedOrderRevision: 0,
                plannedDate: planned.addingTimeInterval(1),
                items: ["虚构检查 A"]
            )
        }
        #expect(throws: MedicalOrderServiceError.crossPatientScope) {
            try service.createFollowUp(
                fromOrderId: order.id,
                patientId: second.id,
                expectedOrderRevision: 0,
                plannedDate: planned,
                items: ["虚构检查 A"]
            )
        }

        let another = try service.createOrder(
            patientId: first.id,
            content: "另一条虚构医嘱"
        )
        #expect(throws: MedicalOrderServiceError.invalidPlannedDate) {
            try service.createFollowUp(
                fromOrderId: another.id,
                patientId: first.id,
                expectedOrderRevision: 0,
                plannedDate: self.now.addingTimeInterval(-86_400),
                items: ["虚构检查 B"]
            )
        }
    }

    @Test("复查创建保存失败回滚链接和新对象")
    func followUpSaveFailureRollsBack() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        let order = MedicalOrder(
            patientId: patient.id,
            content: "虚构医嘱",
            createdAt: now
        )
        context.insert(order)
        try context.save()
        let service = MedicalOrderService(
            context: context,
            saveAction: { _ in throw M4OrderInjectedError.save },
            now: { self.now }
        )

        #expect(throws: MedicalOrderServiceError.databaseSaveFailed) {
            try service.createFollowUp(
                fromOrderId: order.id,
                patientId: patient.id,
                expectedOrderRevision: 0,
                plannedDate: self.now.addingTimeInterval(86_400),
                items: ["虚构检查"]
            )
        }
        #expect(order.generatedFollowUpId == nil)
        #expect(try context.fetchCount(FetchDescriptor<FollowUp>()) == 0)
    }

    @Test("医嘱与复查均支持 CAS 编辑和撤销")
    func orderAndFollowUpSupportCASAndUndo() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        try context.save()
        let service = MedicalOrderService(
            context: context,
            now: { self.now }
        )
        let order = try service.createOrder(
            patientId: patient.id,
            content: "初始虚构医嘱"
        )
        var orderEdit = order.editableContent()
        orderEdit.content = "人工确认后的虚构医嘱"
        _ = try service.editOrder(
            orderId: order.id,
            patientId: patient.id,
            content: orderEdit,
            changedFieldKeys: ["content"],
            expectedRevision: 0
        )
        #expect(
            throws: MedicalOrderServiceError.revisionConflict(
                expected: 0,
                actual: 1
            )
        ) {
            try service.editOrder(
                orderId: order.id,
                patientId: patient.id,
                content: orderEdit,
                changedFieldKeys: ["content"],
                expectedRevision: 0
            )
        }
        _ = try service.undoLastOrder(
            orderId: order.id,
            patientId: patient.id,
            expectedRevision: 1
        )
        #expect(order.content == "初始虚构医嘱")
        #expect(order.contentRevision == 2)

        let followUp = try service.createFollowUp(
            fromOrderId: order.id,
            patientId: patient.id,
            expectedOrderRevision: 2,
            plannedDate: now.addingTimeInterval(86_400),
            items: ["虚构检查 A"]
        )
        var followUpEdit = followUp.editableContent()
        followUpEdit.items = ["虚构检查 A", "虚构检查 B"]
        _ = try service.editFollowUp(
            followUpId: followUp.id,
            patientId: patient.id,
            content: followUpEdit,
            changedFieldKeys: ["items"],
            expectedRevision: 0
        )
        _ = try service.undoLastFollowUp(
            followUpId: followUp.id,
            patientId: patient.id,
            expectedRevision: 1
        )
        #expect(followUp.items == ["虚构检查 A"])
        #expect(followUp.contentRevision == 2)
        #expect(try context.fetchCount(FetchDescriptor<ContentRevision>()) == 4)
    }

    @Test("日期型复查允许今天任意时刻并拒绝昨天")
    func dateOnlyTodayIsAccepted() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let timezone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let startOfToday = calendar.startOfDay(for: now)
        let service = MedicalOrderService(
            context: context,
            now: { self.now },
            businessTimeZone: timezone
        )
        let todayOrder = try service.createOrder(
            patientId: patient.id,
            content: "今天复查"
        )
        let followUp = try service.createFollowUp(
            fromOrderId: todayOrder.id,
            patientId: patient.id,
            expectedOrderRevision: 0,
            plannedDate: startOfToday,
            items: ["虚构检查"]
        )
        #expect(followUp.plannedDate == startOfToday)

        let yesterdayOrder = try service.createOrder(
            patientId: patient.id,
            content: "昨天不可新建"
        )
        let yesterday = try #require(
            calendar.date(byAdding: .day, value: -1, to: startOfToday)
        )
        #expect(throws: MedicalOrderServiceError.invalidPlannedDate) {
            try service.createFollowUp(
                fromOrderId: yesterdayOrder.id,
                patientId: patient.id,
                expectedOrderRevision: 0,
                plannedDate: yesterday,
                items: ["虚构检查"]
            )
        }
    }

    @Test("过期待办可改备注但不能改到另一个过去日期")
    func overduePendingCanEditNonDateFields() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let overdue = FollowUp(
            patientId: patient.id,
            plannedDate: now.addingTimeInterval(-172_800),
            items: ["原项目"],
            reason: "原备注",
            createdAt: now.addingTimeInterval(-259_200)
        )
        context.insert(overdue)
        try context.save()
        let service = MedicalOrderService(
            context: context,
            now: { self.now }
        )
        var noteEdit = overdue.editableContent()
        noteEdit.reason = "修订备注"
        _ = try service.editFollowUp(
            followUpId: overdue.id,
            patientId: patient.id,
            content: noteEdit,
            changedFieldKeys: ["reason"],
            expectedRevision: 0
        )
        #expect(overdue.reason == "修订备注")

        var dateEdit = overdue.editableContent()
        dateEdit.plannedDate = now.addingTimeInterval(-86_400)
        #expect(throws: MedicalOrderServiceError.invalidCompletionState) {
            try service.editFollowUp(
                followUpId: overdue.id,
                patientId: patient.id,
                content: dateEdit,
                changedFieldKeys: ["plannedDate"],
                expectedRevision: 1
            )
        }
    }

    @Test("携带记录引用拒绝跨成员")
    func bringRecordCrossPatientRejected() throws {
        let fixture = try makeRecordFixture()
        var content = fixture.followUp.editableContent()
        content.bringRecordIds = [fixture.otherRecord.id]
        #expect(throws: MedicalOrderServiceError.crossPatientScope) {
            try fixture.service.editFollowUp(
                followUpId: fixture.followUp.id,
                patientId: fixture.patient.id,
                content: content,
                changedFieldKeys: ["bringRecordIds"],
                expectedRevision: 0
            )
        }
    }

    @Test("对比记录引用拒绝跨成员")
    func compareRecordCrossPatientRejected() throws {
        let fixture = try makeRecordFixture()
        var content = fixture.followUp.editableContent()
        content.compareRecordId = fixture.otherRecord.id
        #expect(throws: MedicalOrderServiceError.crossPatientScope) {
            try fixture.service.editFollowUp(
                followUpId: fixture.followUp.id,
                patientId: fixture.patient.id,
                content: content,
                changedFieldKeys: ["compareRecordId"],
                expectedRevision: 0
            )
        }
    }

    @Test("结果记录引用拒绝跨成员")
    func resultRecordCrossPatientRejected() throws {
        let fixture = try makeRecordFixture()
        var content = fixture.followUp.editableContent()
        content.resultRecordId = fixture.otherRecord.id
        #expect(throws: MedicalOrderServiceError.crossPatientScope) {
            try fixture.service.editFollowUp(
                followUpId: fixture.followUp.id,
                patientId: fixture.patient.id,
                content: content,
                changedFieldKeys: ["resultRecordId"],
                expectedRevision: 0
            )
        }
    }

    @Test("复查引用拒绝不存在和重复记录")
    func invalidRecordReferencesRejected() throws {
        let fixture = try makeRecordFixture()
        var missing = fixture.followUp.editableContent()
        missing.bringRecordIds = [UUID()]
        #expect(throws: MedicalOrderServiceError.linkedRecordMissing) {
            try fixture.service.editFollowUp(
                followUpId: fixture.followUp.id,
                patientId: fixture.patient.id,
                content: missing,
                changedFieldKeys: ["bringRecordIds"],
                expectedRevision: 0
            )
        }
        var duplicate = fixture.followUp.editableContent()
        duplicate.bringRecordIds = [
            fixture.patientRecord.id,
            fixture.patientRecord.id
        ]
        #expect(throws: MedicalOrderServiceError.duplicateRecordReference) {
            try fixture.service.editFollowUp(
                followUpId: fixture.followUp.id,
                patientId: fixture.patient.id,
                content: duplicate,
                changedFieldKeys: ["bringRecordIds"],
                expectedRevision: 0
            )
        }
    }

    @Test("复查完成原子关闭提醒且拒绝未来完成时间")
    func completionClosesReminder() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let followUp = FollowUp(
            patientId: patient.id,
            plannedDate: now.addingTimeInterval(86_400),
            items: ["虚构检查"],
            reminderEnabled: true,
            createdAt: now.addingTimeInterval(-86_400)
        )
        context.insert(followUp)
        try context.save()
        let service = MedicalOrderService(
            context: context,
            now: { self.now }
        )
        var futureCompletion = followUp.editableContent()
        futureCompletion.status = .completed
        futureCompletion.completedAt = now.addingTimeInterval(1)
        #expect(throws: MedicalOrderServiceError.invalidCompletionState) {
            try service.editFollowUp(
                followUpId: followUp.id,
                patientId: patient.id,
                content: futureCompletion,
                changedFieldKeys: ["status", "completedAt"],
                expectedRevision: 0
            )
        }

        var completed = followUp.editableContent()
        completed.status = .completed
        completed.completedAt = now
        completed.reminderEnabled = true
        let revision = try service.editFollowUp(
            followUpId: followUp.id,
            patientId: patient.id,
            content: completed,
            changedFieldKeys: ["status", "completedAt"],
            expectedRevision: 0
        )
        #expect(followUp.status == .completed)
        #expect(followUp.reminderEnabled == false)
        #expect(revision.changedFieldKeys.contains("reminderEnabled"))
    }

    @Test("复查和医嘱拒绝非有限日期及超长文本")
    func dateAndTextBounds() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicalOrderService(
            context: context,
            now: { self.now }
        )
        #expect(
            throws: MedicalOrderServiceError.textTooLong(field: "content")
        ) {
            try service.createOrder(
                patientId: patient.id,
                content: String(
                    repeating: "医",
                    count: DomainFieldPolicy.noteMaximumUTF8Bytes
                )
            )
        }
        for value in [Double.nan, .infinity, -.infinity] {
            let order = try service.createOrder(
                patientId: patient.id,
                content: "非法日期 \(value)"
            )
            #expect(throws: MedicalOrderServiceError.invalidPlannedDate) {
                try service.createFollowUp(
                    fromOrderId: order.id,
                    patientId: patient.id,
                    expectedOrderRevision: 0,
                    plannedDate: Date(timeIntervalSince1970: value),
                    items: ["虚构检查"]
                )
            }
        }
    }

    @Test("陈旧 ModelContext 无法覆盖医嘱")
    func staleOrderContextCASRejected() throws {
        let container = try TestSupport.container()
        let patient = Patient(name: "虚构成员")
        container.mainContext.insert(patient)
        try container.mainContext.save()
        let order = try MedicalOrderService(context: container.mainContext)
            .createOrder(patientId: patient.id, content: "原医嘱")
        let firstContext = ModelContext(container)
        let staleContext = ModelContext(container)
        let first = try #require(
            firstContext.model(for: order.persistentModelID) as? MedicalOrder
        )
        let stale = try #require(
            staleContext.model(for: order.persistentModelID) as? MedicalOrder
        )
        var firstContent = first.editableContent()
        firstContent.content = "先提交"
        _ = try MedicalOrderService(context: firstContext).editOrder(
            orderId: first.id,
            patientId: patient.id,
            content: firstContent,
            changedFieldKeys: ["content"],
            expectedRevision: 0
        )
        var staleContent = stale.editableContent()
        staleContent.content = "陈旧覆盖"
        #expect(
            throws: MedicalOrderServiceError.revisionConflict(
                expected: 0,
                actual: 1
            )
        ) {
            try MedicalOrderService(context: staleContext).editOrder(
                orderId: stale.id,
                patientId: patient.id,
                content: staleContent,
                changedFieldKeys: ["content"],
                expectedRevision: 0
            )
        }
    }

    @Test("复查创建失败在 fresh context 中保持医嘱无链接")
    func followUpRollbackVerifiedInFreshContext() throws {
        let container = try TestSupport.container()
        let patient = Patient(name: "虚构成员")
        container.mainContext.insert(patient)
        try container.mainContext.save()
        let order = try MedicalOrderService(context: container.mainContext)
            .createOrder(patientId: patient.id, content: "虚构医嘱")
        let failing = MedicalOrderService(
            context: container.mainContext,
            saveAction: { _ in throw M4OrderInjectedError.save },
            now: { self.now }
        )
        #expect(throws: MedicalOrderServiceError.databaseSaveFailed) {
            try failing.createFollowUp(
                fromOrderId: order.id,
                patientId: patient.id,
                expectedOrderRevision: 0,
                plannedDate: self.now.addingTimeInterval(86_400),
                items: ["虚构检查"]
            )
        }
        let verification = ModelContext(container)
        let persisted = try #require(
            verification.model(for: order.persistentModelID) as? MedicalOrder
        )
        #expect(persisted.generatedFollowUpId == nil)
        #expect(
            try verification.fetchCount(FetchDescriptor<FollowUp>()) == 0
        )
    }

    @Test("重复 sourceOrderId 数据被完整性检查拒绝")
    func duplicateSourceOrderRowsRejected() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let order = MedicalOrder(
            patientId: patient.id,
            content: "虚构医嘱",
            createdAt: now
        )
        context.insert(order)
        context.insert(
            FollowUp(
                patientId: patient.id,
                sourceOrderId: order.id,
                plannedDate: now.addingTimeInterval(86_400),
                items: ["A"]
            )
        )
        context.insert(
            FollowUp(
                patientId: patient.id,
                sourceOrderId: order.id,
                plannedDate: now.addingTimeInterval(172_800),
                items: ["B"]
            )
        )
        try context.save()
        #expect(throws: MedicalOrderServiceError.duplicateOrderFollowUp) {
            try MedicalOrderService(
                context: context,
                now: { self.now }
            ).createFollowUp(
                fromOrderId: order.id,
                patientId: patient.id,
                expectedOrderRevision: 0,
                plannedDate: self.now.addingTimeInterval(86_400),
                items: ["A"]
            )
        }
    }

    private func makePatientContext() throws -> (
        container: ModelContainer,
        patient: Patient
    ) {
        let container = try TestSupport.container()
        let patient = Patient(name: "虚构成员")
        container.mainContext.insert(patient)
        try container.mainContext.save()
        return (container, patient)
    }

    private func makeRecordFixture() throws -> (
        container: ModelContainer,
        service: MedicalOrderService,
        patient: Patient,
        patientRecord: MedicalRecord,
        otherRecord: MedicalRecord,
        followUp: FollowUp
    ) {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "甲")
        let other = Patient(name: "乙")
        let patientRecord = MedicalRecord(
            patientId: patient.id,
            title: "甲记录",
            eventDate: now
        )
        let otherRecord = MedicalRecord(
            patientId: other.id,
            title: "乙记录",
            eventDate: now
        )
        let followUp = FollowUp(
            patientId: patient.id,
            plannedDate: now.addingTimeInterval(86_400),
            items: ["虚构检查"]
        )
        [patient, other].forEach(context.insert)
        [patientRecord, otherRecord].forEach(context.insert)
        context.insert(followUp)
        try context.save()
        return (
            container,
            MedicalOrderService(context: context, now: { self.now }),
            patient,
            patientRecord,
            otherRecord,
            followUp
        )
    }
}

private enum M4OrderInjectedError: Error {
    case save
}
