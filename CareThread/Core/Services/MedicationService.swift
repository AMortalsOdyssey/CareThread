import Foundation
import SwiftData

enum MedicationServiceError: Error, Equatable {
    case patientMissing
    case medicationMissing
    case sourceRecordMissing
    case crossPatientScope
    case emptyName
    case emptyDoseUnit
    case textTooLong(field: String)
    case invalidDose
    case invalidDate
    case endBeforeStart
    case inconsistentDuration
    case invalidWeeklyCount
    case unexpectedWeeklyCount
    case invalidReminderTime
    case duplicateReminderTime
    case reminderTimeCount(expected: Int, actual: Int)
    case asNeededCannotAutoSchedule
    case invalidRemainingQuantity
    case invalidRefillReminderDate
    case inactiveMedication
    case invalidLifecycleTransition
    case revisionConflict(expected: Int, actual: Int)
    case payloadEncodingFailed
    case databaseSaveFailed
}

@MainActor
final class MedicationService {
    typealias SaveAction = @MainActor (ModelContext) throws -> Void

    private let context: ModelContext
    private let saveAction: SaveAction
    private let now: @MainActor () -> Date

    init(
        context: ModelContext,
        saveAction: @escaping SaveAction = { try $0.save() },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.context = context
        self.saveAction = saveAction
        self.now = now
    }

    func create(_ draft: MedicationDraft) throws -> Medication {
        guard MemberIdentity.optionalTrimmed(draft.name) != nil else {
            throw MedicationServiceError.emptyName
        }
        guard try fetchPatient(id: draft.patientId) != nil else {
            throw MedicationServiceError.patientMissing
        }
        try validateSourceRecord(
            id: draft.sourceRecordId,
            patientId: draft.patientId
        )
        let createdAt = now()
        guard DomainFieldPolicy.isFinite(createdAt) else {
            throw MedicationServiceError.invalidDate
        }
        let medication = Medication(
            patientId: draft.patientId,
            name: MemberIdentity.normalizedDisplayName(draft.name),
            doseValue: draft.doseValue,
            doseUnit: draft.doseUnit.trimmingCharacters(in: .whitespacesAndNewlines),
            frequency: draft.frequency,
            weeklyCount: draft.weeklyCount,
            usageNotes: normalizedNotes(draft.usageNotes),
            startDate: draft.startDate,
            endDate: draft.endDate,
            isLongTerm: draft.isLongTerm,
            hospital: MemberIdentity.optionalTrimmed(draft.hospital),
            department: MemberIdentity.optionalTrimmed(draft.department),
            linkedDiagnosis: MemberIdentity.optionalTrimmed(draft.linkedDiagnosis),
            caution: MemberIdentity.optionalTrimmed(draft.caution),
            sourceRecordId: draft.sourceRecordId,
            reminderEnabled: draft.reminderEnabled,
            reminderTimes: draft.reminderTimes,
            remainingQuantity: draft.remainingQuantity,
            refillReminderAt: draft.refillReminderAt,
            createdAt: createdAt
        )
        try validate(medication.editableContent())
        context.insert(medication)
        do {
            try saveAction(context)
            return medication
        } catch {
            context.rollback()
            throw MedicationServiceError.databaseSaveFailed
        }
    }

    @discardableResult
    func edit(
        medicationId: UUID,
        patientId: UUID,
        content: MedicationEditableContent,
        changedFieldKeys: [String],
        expectedRevision: Int
    ) throws -> ContentRevision {
        let medication = try scopedMedication(
            id: medicationId,
            patientId: patientId
        )
        guard content.lifecycleStatus == medication.lifecycleStatus else {
            throw MedicationServiceError.invalidLifecycleTransition
        }
        let normalizedContent = normalized(content)
        try validate(normalizedContent)
        do {
            return try revisionService.edit(
                medication,
                content: normalizedContent,
                changedFieldKeys: changedFieldKeys,
                source: .manual,
                expectedRevision: expectedRevision
            )
        } catch let error as ContentRevisionServiceError {
            throw mapRevisionError(error)
        }
    }

    /// Closes the current immutable version and creates its successor in the
    /// same save. Medication intervals are half-open (`startDate <= t <
    /// endDate`), so sharing `effectiveAt` as the old exclusive end and new
    /// inclusive start has no overlap. The previousVersionId/source scope
    /// cannot be caller-edited.
    func adjustDose(
        medicationId: UUID,
        patientId: UUID,
        expectedRevision: Int,
        doseValue: Double,
        doseUnit: String,
        effectiveAt: Date
    ) throws -> Medication {
        let current = try scopedMedication(
            id: medicationId,
            patientId: patientId
        )
        try validateCAS(current, expectedRevision: expectedRevision)
        guard current.lifecycleStatus == .active else {
            throw MedicationServiceError.inactiveMedication
        }
        guard doseValue > 0, doseValue.isFinite else {
            throw MedicationServiceError.invalidDose
        }
        guard DomainFieldPolicy.isFinite(effectiveAt),
              effectiveAt > current.startDate,
              current.endDate.map({ effectiveAt < $0 }) ?? true else {
            throw MedicationServiceError.endBeforeStart
        }

        let before = current.editableContent()
        let beforeRevision = current.contentRevision
        let timestamp = now()
        var closed = before
        closed.endDate = effectiveAt
        closed.isLongTerm = false
        closed.lifecycleStatus = .superseded
        closed.reminderEnabled = false
        closed.refillReminderAt = nil
        closed.updatedAt = timestamp
        try validate(closed)

        var successorContent = before
        successorContent.doseValue = doseValue
        successorContent.doseUnit = doseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        successorContent.startDate = effectiveAt
        successorContent.lifecycleStatus = .active
        successorContent.updatedAt = timestamp
        try validate(successorContent)

        let beforePayload: Data
        do {
            beforePayload = try ModelPayload.encode(before)
        } catch {
            throw MedicationServiceError.payloadEncodingFailed
        }

        current.applyEditableContent(closed)
        current.bumpContentRevision()
        let afterPayload: Data
        do {
            afterPayload = try ModelPayload.encode(current.editableContent())
        } catch {
            current.applyEditableContent(before)
            current.restoreContentRevision(beforeRevision)
            throw MedicationServiceError.payloadEncodingFailed
        }
        let successor = Medication(
            patientId: current.patientId,
            name: successorContent.name,
            doseValue: successorContent.doseValue,
            doseUnit: successorContent.doseUnit,
            frequency: successorContent.frequency,
            weeklyCount: successorContent.weeklyCount,
            usageNotes: successorContent.usageNotes,
            startDate: successorContent.startDate,
            endDate: successorContent.endDate,
            isLongTerm: successorContent.isLongTerm,
            hospital: successorContent.hospital,
            department: successorContent.department,
            linkedDiagnosis: successorContent.linkedDiagnosis,
            caution: successorContent.caution,
            sourceRecordId: current.sourceRecordId,
            previousVersionId: current.id,
            reminderEnabled: successorContent.reminderEnabled,
            reminderTimes: successorContent.reminderTimes,
            remainingQuantity: successorContent.remainingQuantity,
            refillReminderAt: successorContent.refillReminderAt,
            lifecycleStatus: .active,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let audit = ContentRevision(
            entityKind: .medication,
            entityId: current.id,
            patientId: current.patientId,
            revision: current.contentRevision,
            changedFieldKeys: [
                "doseValue",
                "doseUnit",
                "endDate",
                "lifecycleStatus",
                "reminderEnabled",
                "refillReminderAt"
            ],
            beforeContentPayload: beforePayload,
            afterContentPayload: afterPayload,
            source: .manual,
            createdAt: timestamp
        )
        context.insert(successor)
        context.insert(audit)
        do {
            try saveAction(context)
            return successor
        } catch {
            context.rollback()
            current.applyEditableContent(before)
            current.restoreContentRevision(beforeRevision)
            throw MedicationServiceError.databaseSaveFailed
        }
    }

    @discardableResult
    func updateRefill(
        medicationId: UUID,
        patientId: UUID,
        remainingQuantity: Double?,
        refillReminderAt: Date?,
        expectedRevision: Int
    ) throws -> ContentRevision {
        let medication = try scopedMedication(
            id: medicationId,
            patientId: patientId
        )
        guard medication.lifecycleStatus == .active else {
            throw MedicationServiceError.inactiveMedication
        }
        var content = medication.editableContent()
        content.remainingQuantity = remainingQuantity
        content.refillReminderAt = refillReminderAt
        content.updatedAt = now()
        return try edit(
            medicationId: medicationId,
            patientId: patientId,
            content: content,
            changedFieldKeys: ["remainingQuantity", "refillReminderAt"],
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func snoozeRefill(
        medicationId: UUID,
        patientId: UUID,
        until date: Date,
        expectedRevision: Int
    ) throws -> ContentRevision {
        guard DomainFieldPolicy.isFinite(date), date > now() else {
            throw MedicationServiceError.invalidRefillReminderDate
        }
        let medication = try scopedMedication(
            id: medicationId,
            patientId: patientId
        )
        return try updateRefill(
            medicationId: medicationId,
            patientId: patientId,
            remainingQuantity: medication.remainingQuantity,
            refillReminderAt: date,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func complete(
        medicationId: UUID,
        patientId: UUID,
        at date: Date,
        expectedRevision: Int
    ) throws -> ContentRevision {
        try changeLifecycle(
            medicationId: medicationId,
            patientId: patientId,
            status: .completed,
            at: date,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func discontinue(
        medicationId: UUID,
        patientId: UUID,
        at date: Date,
        expectedRevision: Int
    ) throws -> ContentRevision {
        try changeLifecycle(
            medicationId: medicationId,
            patientId: patientId,
            status: .discontinued,
            at: date,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func undoLast(
        medicationId: UUID,
        patientId: UUID,
        expectedRevision: Int
    ) throws -> ContentRevision {
        let medication = try scopedMedication(
            id: medicationId,
            patientId: patientId
        )
        do {
            return try revisionService.undoLast(
                medication,
                expectedRevision: expectedRevision
            )
        } catch let error as ContentRevisionServiceError {
            throw mapRevisionError(error)
        }
    }

    private var revisionService: ContentRevisionService {
        ContentRevisionService(context: context, saveAction: saveAction)
    }

    private func changeLifecycle(
        medicationId: UUID,
        patientId: UUID,
        status: MedicationLifecycleStatus,
        at date: Date,
        expectedRevision: Int
    ) throws -> ContentRevision {
        let medication = try scopedMedication(
            id: medicationId,
            patientId: patientId
        )
        guard medication.lifecycleStatus == .active else {
            throw MedicationServiceError.inactiveMedication
        }
        guard DomainFieldPolicy.isFinite(date),
              date > medication.startDate,
              medication.endDate.map({ date <= $0 }) ?? true else {
            throw MedicationServiceError.endBeforeStart
        }
        var content = medication.editableContent()
        content.lifecycleStatus = status
        content.endDate = date
        content.isLongTerm = false
        content.reminderEnabled = false
        content.refillReminderAt = nil
        content.updatedAt = now()
        try validate(content)
        do {
            return try revisionService.edit(
                medication,
                content: normalized(content),
                changedFieldKeys: [
                "lifecycleStatus",
                "endDate",
                "isLongTerm",
                "reminderEnabled",
                "refillReminderAt"
                ],
                source: .manual,
                expectedRevision: expectedRevision
            )
        } catch let error as ContentRevisionServiceError {
            throw mapRevisionError(error)
        }
    }

    private func validate(_ content: MedicationEditableContent) throws {
        guard let name = MemberIdentity.optionalTrimmed(content.name) else {
            throw MedicationServiceError.emptyName
        }
        guard DomainFieldPolicy.isWithinUTF8Limit(
            name,
            maximum: DomainFieldPolicy.shortTextMaximumUTF8Bytes
        ) else {
            throw MedicationServiceError.textTooLong(field: "name")
        }
        let unit = content.doseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty else {
            throw MedicationServiceError.emptyDoseUnit
        }
        guard DomainFieldPolicy.isWithinUTF8Limit(
            unit,
            maximum: DomainFieldPolicy.unitMaximumUTF8Bytes
        ) else {
            throw MedicationServiceError.textTooLong(field: "doseUnit")
        }
        guard let dose = content.doseValue, dose > 0, dose.isFinite else {
            throw MedicationServiceError.invalidDose
        }
        guard DomainFieldPolicy.isFinite(content.startDate),
              DomainFieldPolicy.isFinite(content.updatedAt),
              content.endDate.map(DomainFieldPolicy.isFinite) ?? true,
              content.refillReminderAt.map(DomainFieldPolicy.isFinite) ?? true else {
            throw MedicationServiceError.invalidDate
        }
        if let endDate = content.endDate, endDate < content.startDate {
            throw MedicationServiceError.endBeforeStart
        }
        guard content.isLongTerm == (content.endDate == nil) else {
            throw MedicationServiceError.inconsistentDuration
        }
        if let quantity = content.remainingQuantity,
           quantity < 0 || !quantity.isFinite {
            throw MedicationServiceError.invalidRemainingQuantity
        }
        if let refillDate = content.refillReminderAt,
           refillDate < content.startDate {
            throw MedicationServiceError.invalidRefillReminderDate
        }
        guard content.usageNotes.count <= DomainFieldPolicy.listMaximumCount,
              content.usageNotes.allSatisfy({
                  DomainFieldPolicy.isWithinUTF8Limit(
                      $0,
                      maximum: DomainFieldPolicy.listItemMaximumUTF8Bytes
                  )
              }) else {
            throw MedicationServiceError.textTooLong(field: "usageNotes")
        }
        for (field, value) in [
            ("hospital", content.hospital),
            ("department", content.department),
            ("linkedDiagnosis", content.linkedDiagnosis),
            ("caution", content.caution)
        ] {
            guard value.map({
                DomainFieldPolicy.isWithinUTF8Limit(
                    $0,
                    maximum: DomainFieldPolicy.noteMaximumUTF8Bytes
                )
            }) ?? true else {
                throw MedicationServiceError.textTooLong(field: field)
            }
        }
        switch content.lifecycleStatus {
        case .active:
            break
        case .completed, .discontinued, .superseded:
            guard content.endDate != nil,
                  !content.isLongTerm,
                  !content.reminderEnabled,
                  content.refillReminderAt == nil else {
                throw MedicationServiceError.invalidLifecycleTransition
            }
        }
        do {
            try FrequencySchedulePolicy.validate(
                frequency: content.frequency,
                weeklyCount: content.weeklyCount,
                reminderEnabled: content.reminderEnabled,
                reminderTimes: content.reminderTimes
            )
        } catch let error as FrequencySchedulePolicyError {
            throw mapScheduleError(error)
        }
    }

    private func normalized(
        _ content: MedicationEditableContent
    ) -> MedicationEditableContent {
        var result = content
        result.name = MemberIdentity.normalizedDisplayName(content.name)
        result.doseUnit = content.doseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        result.usageNotes = normalizedNotes(content.usageNotes)
        result.hospital = MemberIdentity.optionalTrimmed(content.hospital)
        result.department = MemberIdentity.optionalTrimmed(content.department)
        result.linkedDiagnosis = MemberIdentity.optionalTrimmed(content.linkedDiagnosis)
        result.caution = MemberIdentity.optionalTrimmed(content.caution)
        return result
    }

    private func normalizedNotes(_ notes: [String]) -> [String] {
        notes.compactMap(MemberIdentity.optionalTrimmed)
    }

    private func mapScheduleError(
        _ error: FrequencySchedulePolicyError
    ) -> MedicationServiceError {
        switch error {
        case .invalidWeeklyCount:
            .invalidWeeklyCount
        case .unexpectedWeeklyCount:
            .unexpectedWeeklyCount
        case .invalidReminderTime:
            .invalidReminderTime
        case .duplicateReminderTime:
            .duplicateReminderTime
        case let .reminderTimeCount(expected, actual):
            .reminderTimeCount(expected: expected, actual: actual)
        case .asNeededCannotAutoSchedule:
            .asNeededCannotAutoSchedule
        }
    }

    private func scopedMedication(
        id: UUID,
        patientId: UUID
    ) throws -> Medication {
        guard let medication = try fetchMedication(id: id) else {
            throw MedicationServiceError.medicationMissing
        }
        guard medication.patientId == patientId else {
            throw MedicationServiceError.crossPatientScope
        }
        guard try fetchPatient(id: patientId) != nil else {
            throw MedicationServiceError.patientMissing
        }
        return medication
    }

    private func validateCAS(
        _ medication: Medication,
        expectedRevision: Int
    ) throws {
        let probe = ModelContext(context.container)
        guard let persisted = probe.model(
            for: medication.persistentModelID
        ) as? Medication else {
            throw MedicationServiceError.medicationMissing
        }
        let actual = persisted.contentRevision
        guard expectedRevision == actual,
              medication.contentRevision == actual else {
            throw MedicationServiceError.revisionConflict(
                expected: expectedRevision,
                actual: actual
            )
        }
    }

    private func validateSourceRecord(
        id: UUID?,
        patientId: UUID
    ) throws {
        guard let id else { return }
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else {
            throw MedicationServiceError.sourceRecordMissing
        }
        guard record.patientId == patientId else {
            throw MedicationServiceError.crossPatientScope
        }
    }

    private func fetchMedication(id: UUID) throws -> Medication? {
        var descriptor = FetchDescriptor<Medication>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchPatient(id: UUID) throws -> Patient? {
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func mapRevisionError(
        _ error: ContentRevisionServiceError
    ) -> MedicationServiceError {
        switch error {
        case let .revisionConflict(expected, actual):
            .revisionConflict(expected: expected, actual: actual)
        case .payloadEncodingFailed:
            .payloadEncodingFailed
        default:
            .databaseSaveFailed
        }
    }
}
