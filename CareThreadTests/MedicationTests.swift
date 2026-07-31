import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct M4MedicationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("用药创建校验药名、剂量、起止、周频次和提醒时刻")
    func createValidation() throws {
        let container = try TestSupport.container()
        let patient = Patient(name: "虚构成员")
        container.mainContext.insert(patient)
        try container.mainContext.save()
        let service = MedicationService(
            context: container.mainContext,
            now: { self.start.addingTimeInterval(-3_600) }
        )

        #expect(throws: MedicationServiceError.emptyName) {
            try service.create(
                self.draft(patientId: patient.id, name: " ")
            )
        }
        #expect(throws: MedicationServiceError.invalidDose) {
            try service.create(
                self.draft(patientId: patient.id, dose: 0)
            )
        }
        #expect(throws: MedicationServiceError.endBeforeStart) {
            var draft = self.draft(patientId: patient.id)
            draft.endDate = self.start.addingTimeInterval(-1)
            _ = try service.create(draft)
        }
        #expect(throws: MedicationServiceError.invalidWeeklyCount) {
            var draft = self.draft(patientId: patient.id)
            draft.frequency = .weekly
            draft.weeklyCount = 0
            _ = try service.create(draft)
        }
        #expect(
            throws: MedicationServiceError.reminderTimeCount(
                expected: 2,
                actual: 1
            )
        ) {
            var draft = self.draft(patientId: patient.id)
            draft.frequency = .dailyTwo
            _ = try service.create(draft)
        }
    }

    @Test("调整剂量同事务关闭旧版本并建立不可变 previousVersionId 链")
    func doseAdjustmentCreatesVersionChain() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        try context.save()
        let service = MedicationService(
            context: context,
            now: { self.start.addingTimeInterval(10) }
        )
        let original = try service.create(draft(patientId: patient.id))
        let effective = start.addingTimeInterval(86_400)

        let successor = try service.adjustDose(
            medicationId: original.id,
            patientId: patient.id,
            expectedRevision: 0,
            doseValue: 2,
            doseUnit: "片",
            effectiveAt: effective
        )

        #expect(original.lifecycleStatus == .superseded)
        #expect(original.endDate == effective)
        #expect(original.contentRevision == 1)
        #expect(successor.previousVersionId == original.id)
        #expect(successor.patientId == original.patientId)
        #expect(successor.sourceRecordId == original.sourceRecordId)
        #expect(successor.doseValue == 2)
        #expect(successor.lifecycleStatus == .active)
        #expect(!original.isEffective(at: effective))
        #expect(successor.isEffective(at: effective))
        #expect(try context.fetchCount(FetchDescriptor<Medication>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<ContentRevision>()) == 1)
    }

    @Test("调整剂量保存失败回滚旧版本、新版本和审计")
    func doseAdjustmentFailureRollsBack() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        try context.save()
        let original = try MedicationService(context: context)
            .create(draft(patientId: patient.id))
        let failing = MedicationService(
            context: context,
            saveAction: { _ in throw M4InjectedError.save },
            now: { self.start.addingTimeInterval(10) }
        )

        #expect(throws: MedicationServiceError.databaseSaveFailed) {
            try failing.adjustDose(
                medicationId: original.id,
                patientId: patient.id,
                expectedRevision: 0,
                doseValue: 2,
                doseUnit: "片",
                effectiveAt: self.start.addingTimeInterval(86_400)
            )
        }
        #expect(original.lifecycleStatus == .active)
        #expect(original.endDate == nil)
        #expect(original.contentRevision == 0)
        #expect(try context.fetchCount(FetchDescriptor<Medication>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ContentRevision>()) == 0)
    }

    @Test("补药、稍后提醒、完成和撤销均使用 CAS 与审计")
    func refillLifecycleCASAndUndo() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        try context.save()
        let fixedNow = start.addingTimeInterval(-3_600)
        let service = MedicationService(
            context: context,
            now: { fixedNow }
        )
        let medication = try service.create(draft(patientId: patient.id))
        let firstRefill = start.addingTimeInterval(172_800)

        _ = try service.updateRefill(
            medicationId: medication.id,
            patientId: patient.id,
            remainingQuantity: 12,
            refillReminderAt: firstRefill,
            expectedRevision: 0
        )
        #expect(medication.remainingQuantity == 12)
        #expect(medication.refillReminderAt == firstRefill)
        #expect(
            throws: MedicationServiceError.revisionConflict(
                expected: 0,
                actual: 1
            )
        ) {
            try service.snoozeRefill(
                medicationId: medication.id,
                patientId: patient.id,
                until: self.start.addingTimeInterval(259_200),
                expectedRevision: 0
            )
        }
        let snoozed = start.addingTimeInterval(259_200)
        _ = try service.snoozeRefill(
            medicationId: medication.id,
            patientId: patient.id,
            until: snoozed,
            expectedRevision: 1
        )
        _ = try service.complete(
            medicationId: medication.id,
            patientId: patient.id,
            at: start.addingTimeInterval(345_600),
            expectedRevision: 2
        )
        #expect(medication.lifecycleStatus == .completed)
        #expect(medication.reminderEnabled == false)

        _ = try service.undoLast(
            medicationId: medication.id,
            patientId: patient.id,
            expectedRevision: 3
        )
        #expect(medication.lifecycleStatus == .active)
        #expect(medication.refillReminderAt == snoozed)
        #expect(medication.contentRevision == 4)
        #expect(try context.fetchCount(FetchDescriptor<ContentRevision>()) == 4)
    }

    @Test("跨成员修改用药被拒绝")
    func crossPatientRejected() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = Patient(name: "甲")
        let second = Patient(name: "乙")
        context.insert(first)
        context.insert(second)
        try context.save()
        let service = MedicationService(context: context)
        let medication = try service.create(draft(patientId: first.id))

        #expect(throws: MedicationServiceError.crossPatientScope) {
            try service.complete(
                medicationId: medication.id,
                patientId: second.id,
                at: self.start.addingTimeInterval(86_400),
                expectedRevision: 0
            )
        }
    }

    @Test("剂量单位拒绝空白和超长 UTF8 文本")
    func doseUnitValidation() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        var blank = draft(patientId: patient.id)
        blank.doseUnit = " \n "
        #expect(throws: MedicationServiceError.emptyDoseUnit) {
            try service.create(blank)
        }
        var oversized = draft(patientId: patient.id)
        oversized.doseUnit = String(
            repeating: "毫",
            count: DomainFieldPolicy.unitMaximumUTF8Bytes
        )
        #expect(
            throws: MedicationServiceError.textTooLong(field: "doseUnit")
        ) {
            try service.create(oversized)
        }
    }

    @Test("剂量与余量拒绝 NaN 和无穷值")
    func nonFiniteNumbersRejected() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        for value in [Double.nan, .infinity, -.infinity] {
            var invalidDose = draft(patientId: patient.id)
            invalidDose.doseValue = value
            #expect(throws: MedicationServiceError.invalidDose) {
                try service.create(invalidDose)
            }
            var invalidQuantity = draft(patientId: patient.id)
            invalidQuantity.remainingQuantity = value
            #expect(
                throws: MedicationServiceError.invalidRemainingQuantity
            ) {
                try service.create(invalidQuantity)
            }
        }
    }

    @Test("用药日期拒绝 NaN 和无穷值")
    func nonFiniteDatesRejected() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        for value in [Double.nan, .infinity, -.infinity] {
            var invalidStart = draft(patientId: patient.id)
            invalidStart.startDate = Date(timeIntervalSince1970: value)
            #expect(throws: MedicationServiceError.invalidDate) {
                try service.create(invalidStart)
            }
            var invalidRefill = draft(patientId: patient.id)
            invalidRefill.refillReminderAt = Date(
                timeIntervalSince1970: value
            )
            #expect(throws: MedicationServiceError.invalidDate) {
                try service.create(invalidRefill)
            }
        }
    }

    @Test("长期标记与独占结束日期保持一致")
    func durationInvariant() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        var longWithEnd = draft(patientId: patient.id)
        longWithEnd.endDate = start.addingTimeInterval(86_400)
        #expect(throws: MedicationServiceError.inconsistentDuration) {
            try service.create(longWithEnd)
        }
        var finiteWithoutEnd = draft(patientId: patient.id)
        finiteWithoutEnd.isLongTerm = false
        #expect(throws: MedicationServiceError.inconsistentDuration) {
            try service.create(finiteWithoutEnd)
        }
    }

    @Test("剂量调整必须严格位于旧版本内部")
    func doseAdjustmentRequiresStrictInteriorBoundary() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        let open = try service.create(draft(patientId: patient.id))
        #expect(throws: MedicationServiceError.endBeforeStart) {
            try service.adjustDose(
                medicationId: open.id,
                patientId: patient.id,
                expectedRevision: 0,
                doseValue: 2,
                doseUnit: "片",
                effectiveAt: self.start
            )
        }

        var finiteDraft = draft(patientId: patient.id, name: "虚构药品 B")
        finiteDraft.endDate = start.addingTimeInterval(172_800)
        finiteDraft.isLongTerm = false
        let finite = try service.create(finiteDraft)
        #expect(throws: MedicationServiceError.endBeforeStart) {
            try service.adjustDose(
                medicationId: finite.id,
                patientId: patient.id,
                expectedRevision: 0,
                doseValue: 2,
                doseUnit: "片",
                effectiveAt: finiteDraft.endDate!
            )
        }
    }

    @Test("通用编辑不能绕过状态机完成或复活用药")
    func genericEditCannotChangeLifecycle() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        let medication = try service.create(draft(patientId: patient.id))
        var completed = medication.editableContent()
        completed.lifecycleStatus = .completed
        completed.endDate = start.addingTimeInterval(86_400)
        completed.isLongTerm = false
        completed.reminderEnabled = false
        #expect(throws: MedicationServiceError.invalidLifecycleTransition) {
            try service.edit(
                medicationId: medication.id,
                patientId: patient.id,
                content: completed,
                changedFieldKeys: ["lifecycleStatus"],
                expectedRevision: 0
            )
        }
        _ = try service.complete(
            medicationId: medication.id,
            patientId: patient.id,
            at: start.addingTimeInterval(86_400),
            expectedRevision: 0
        )
        var revived = medication.editableContent()
        revived.lifecycleStatus = .active
        revived.endDate = nil
        revived.isLongTerm = true
        #expect(throws: MedicationServiceError.invalidLifecycleTransition) {
            try service.edit(
                medicationId: medication.id,
                patientId: patient.id,
                content: revived,
                changedFieldKeys: ["lifecycleStatus"],
                expectedRevision: 1
            )
        }
    }

    @Test("完成和停用原子关闭补药提醒")
    func inactiveLifecycleClosesRefillReminder() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(
            context: context,
            now: { self.start.addingTimeInterval(-3_600) }
        )
        var value = draft(patientId: patient.id)
        value.refillReminderAt = start.addingTimeInterval(43_200)
        let completed = try service.create(value)
        _ = try service.complete(
            medicationId: completed.id,
            patientId: patient.id,
            at: start.addingTimeInterval(86_400),
            expectedRevision: 0
        )
        #expect(completed.refillReminderAt == nil)
        #expect(completed.reminderEnabled == false)
        #expect(throws: MedicationServiceError.inactiveMedication) {
            try service.snoozeRefill(
                medicationId: completed.id,
                patientId: patient.id,
                until: self.start.addingTimeInterval(172_800),
                expectedRevision: 1
            )
        }

        let discontinued = try service.create(
            draft(patientId: patient.id, name: "虚构药品 C")
        )
        _ = try service.discontinue(
            medicationId: discontinued.id,
            patientId: patient.id,
            at: start.addingTimeInterval(86_400),
            expectedRevision: 0
        )
        #expect(discontinued.lifecycleStatus == .discontinued)
        #expect(throws: MedicationServiceError.inactiveMedication) {
            try service.updateRefill(
                medicationId: discontinued.id,
                patientId: patient.id,
                remainingQuantity: 1,
                refillReminderAt: nil,
                expectedRevision: 1
            )
        }
    }

    @Test("按需用药不允许自动排期")
    func asNeededSchedulePolicy() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        var allowed = draft(patientId: patient.id)
        allowed.frequency = .asNeeded
        allowed.reminderEnabled = false
        allowed.reminderTimes = []
        _ = try service.create(allowed)

        var rejected = allowed
        rejected.reminderEnabled = true
        #expect(throws: MedicationServiceError.asNeededCannotAutoSchedule) {
            try service.create(rejected)
        }
    }

    @Test("陈旧 ModelContext 无法覆盖已提交用药")
    func staleContextCASRejected() throws {
        let container = try TestSupport.container()
        let patient = Patient(name: "虚构成员")
        container.mainContext.insert(patient)
        try container.mainContext.save()
        let medication = try MedicationService(context: container.mainContext)
            .create(draft(patientId: patient.id))
        let firstContext = ModelContext(container)
        let staleContext = ModelContext(container)
        let first = try #require(
            firstContext.model(for: medication.persistentModelID) as? Medication
        )
        let stale = try #require(
            staleContext.model(for: medication.persistentModelID) as? Medication
        )
        var firstEdit = first.editableContent()
        firstEdit.name = "先提交"
        _ = try MedicationService(context: firstContext).edit(
            medicationId: first.id,
            patientId: patient.id,
            content: firstEdit,
            changedFieldKeys: ["name"],
            expectedRevision: 0
        )
        var staleEdit = stale.editableContent()
        staleEdit.name = "陈旧覆盖"
        #expect(
            throws: MedicationServiceError.revisionConflict(
                expected: 0,
                actual: 1
            )
        ) {
            try MedicationService(context: staleContext).edit(
                medicationId: stale.id,
                patientId: patient.id,
                content: staleEdit,
                changedFieldKeys: ["name"],
                expectedRevision: 0
            )
        }
    }

    @Test("剂量调整失败在 fresh context 中也完整回滚")
    func doseRollbackVerifiedInFreshContext() throws {
        let container = try TestSupport.container()
        let patient = Patient(name: "虚构成员")
        container.mainContext.insert(patient)
        try container.mainContext.save()
        let original = try MedicationService(context: container.mainContext)
            .create(draft(patientId: patient.id))
        let failing = MedicationService(
            context: container.mainContext,
            saveAction: { _ in throw M4InjectedError.save }
        )
        #expect(throws: MedicationServiceError.databaseSaveFailed) {
            try failing.adjustDose(
                medicationId: original.id,
                patientId: patient.id,
                expectedRevision: 0,
                doseValue: 2,
                doseUnit: "片",
                effectiveAt: self.start.addingTimeInterval(86_400)
            )
        }
        let verification = ModelContext(container)
        let persisted = try #require(
            verification.model(
                for: original.persistentModelID
            ) as? Medication
        )
        #expect(persisted.lifecycleStatus == .active)
        #expect(persisted.endDate == nil)
        #expect(persisted.contentRevision == 0)
        #expect(
            try verification.fetchCount(FetchDescriptor<Medication>()) == 1
        )
        #expect(
            try verification.fetchCount(
                FetchDescriptor<ContentRevision>()
            ) == 0
        )
    }

    @Test("超长药名和用法列表被领域层拒绝")
    func medicationTextBounds() throws {
        let fixture = try makePatientContext()
        let context = fixture.container.mainContext
        let patient = fixture.patient
        let service = MedicationService(context: context)
        var longName = draft(patientId: patient.id)
        longName.name = String(
            repeating: "药",
            count: DomainFieldPolicy.shortTextMaximumUTF8Bytes
        )
        #expect(throws: MedicationServiceError.textTooLong(field: "name")) {
            try service.create(longName)
        }
        var tooManyNotes = draft(patientId: patient.id)
        tooManyNotes.usageNotes = Array(
            repeating: "虚构用法",
            count: DomainFieldPolicy.listMaximumCount + 1
        )
        #expect(
            throws: MedicationServiceError.textTooLong(field: "usageNotes")
        ) {
            try service.create(tooManyNotes)
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

    private func draft(
        patientId: UUID,
        name: String = "虚构药品 A",
        dose: Double = 1
    ) -> MedicationDraft {
        MedicationDraft(
            patientId: patientId,
            name: name,
            doseValue: dose,
            doseUnit: "片",
            frequency: .dailyOne,
            startDate: start,
            reminderEnabled: true,
            reminderTimes: [ReminderTime(hour: 8, minute: 0)]
        )
    }
}

private enum M4InjectedError: Error {
    case save
}
