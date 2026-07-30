import Foundation
import SwiftData

enum MedicalOrderServiceError: Error, Equatable {
    case noChanges
    case patientMissing
    case orderMissing
    case followUpMissing
    case sourceRecordMissing
    case linkedRecordMissing
    case crossPatientScope
    case emptyOrderContent
    case emptyFollowUpItems
    case duplicateRecordReference
    case textTooLong(field: String)
    case invalidDate
    case invalidPlannedDate
    case invalidCompletionState
    case duplicateOrderFollowUp
    case revisionConflict(expected: Int, actual: Int)
    case databaseSaveFailed
}

@MainActor
final class MedicalOrderService {
    typealias SaveAction = @MainActor (ModelContext) throws -> Void

    private let context: ModelContext
    private let saveAction: SaveAction
    private let now: @MainActor () -> Date
    private let businessTimeZone: TimeZone

    init(
        context: ModelContext,
        saveAction: @escaping SaveAction = { try $0.save() },
        now: @escaping @MainActor () -> Date = Date.init,
        businessTimeZone: TimeZone = .current
    ) {
        self.context = context
        self.saveAction = saveAction
        self.now = now
        self.businessTimeZone = businessTimeZone
    }

    func createOrder(
        patientId: UUID,
        content: String,
        sourceRecordId: UUID? = nil
    ) throws -> MedicalOrder {
        guard try fetchPatient(id: patientId) != nil else {
            throw MedicalOrderServiceError.patientMissing
        }
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else {
            throw MedicalOrderServiceError.emptyOrderContent
        }
        guard DomainFieldPolicy.isWithinUTF8Limit(
            normalizedContent,
            maximum: DomainFieldPolicy.noteMaximumUTF8Bytes
        ) else {
            throw MedicalOrderServiceError.textTooLong(field: "content")
        }
        try validateSourceRecord(id: sourceRecordId, patientId: patientId)
        let order = MedicalOrder(
            patientId: patientId,
            content: normalizedContent,
            sourceRecordId: sourceRecordId,
            createdAt: now()
        )
        context.insert(order)
        do {
            try saveAction(context)
            return order
        } catch {
            context.rollback()
            throw MedicalOrderServiceError.databaseSaveFailed
        }
    }

    @discardableResult
    func editOrder(
        orderId: UUID,
        patientId: UUID,
        content: MedicalOrderEditableContent,
        changedFieldKeys: [String],
        expectedRevision: Int
    ) throws -> ContentRevision {
        let order = try scopedOrder(id: orderId, patientId: patientId)
        guard !content.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MedicalOrderServiceError.emptyOrderContent
        }
        var normalized = content
        normalized.content = content.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DomainFieldPolicy.isWithinUTF8Limit(
            normalized.content,
            maximum: DomainFieldPolicy.noteMaximumUTF8Bytes
        ) else {
            throw MedicalOrderServiceError.textTooLong(field: "content")
        }
        let before = order.editableContent()
        // updatedAt is system-maintained by the revision commit.
        normalized.updatedAt = before.updatedAt
        var actualKeys: [String] = []
        if before.content != normalized.content {
            actualKeys.append("content")
        }
        if before.isCompleted != normalized.isCompleted {
            actualKeys.append("isCompleted")
        }
        // A stale form must be rejected even when its submitted values happen
        // to match the local context's snapshot. Otherwise `noChanges` would
        // mask a concurrent persisted edit.
        try validateCAS(order, expectedRevision: expectedRevision)
        guard !actualKeys.isEmpty else {
            throw MedicalOrderServiceError.noChanges
        }
        do {
            return try revisionService.edit(
                order,
                content: normalized,
                changedFieldKeys: actualKeys + changedFieldKeys.filter {
                    actualKeys.contains($0)
                },
                source: .manual,
                expectedRevision: expectedRevision
            )
        } catch let error as ContentRevisionServiceError {
            throw mapRevisionError(error)
        }
    }

    @discardableResult
    func editFollowUp(
        followUpId: UUID,
        patientId: UUID,
        content: FollowUpEditableContent,
        changedFieldKeys: [String],
        expectedRevision: Int
    ) throws -> ContentRevision {
        let followUp = try scopedFollowUp(
            id: followUpId,
            patientId: patientId
        )
        let normalized = try normalizedFollowUp(
            content,
            current: followUp
        )
        try validateRecordReferences(
            normalized,
            patientId: patientId,
            existingContent: followUp.editableContent()
        )
        var keys = changedFieldKeys
        if normalized.reminderEnabled != content.reminderEnabled {
            keys.append("reminderEnabled")
        }
        do {
            return try revisionService.edit(
                followUp,
                content: normalized,
                changedFieldKeys: keys,
                source: .manual,
                expectedRevision: expectedRevision
            )
        } catch let error as ContentRevisionServiceError {
            throw mapRevisionError(error)
        }
    }

    /// Creates at most one FollowUp per source order. Repeating the identical
    /// command returns the existing row; a conflicting command is rejected.
    func createFollowUp(
        fromOrderId orderId: UUID,
        patientId: UUID,
        expectedOrderRevision: Int,
        plannedDate: Date,
        items: [String],
        reason: String? = nil,
        reminderEnabled: Bool = true
    ) throws -> FollowUp {
        let order = try scopedOrder(id: orderId, patientId: patientId)
        let normalizedItems = items.compactMap {
            MemberIdentity.optionalTrimmed($0)
        }
        let normalizedReason = MemberIdentity.optionalTrimmed(reason)

        if let existing = try fetchFollowUp(sourceOrderId: orderId) {
            guard existing.patientId == patientId else {
                throw MedicalOrderServiceError.crossPatientScope
            }
            guard existing.plannedDate == plannedDate,
                  existing.items == normalizedItems,
                  existing.reason == normalizedReason,
                  existing.reminderEnabled == reminderEnabled else {
                throw MedicalOrderServiceError.duplicateOrderFollowUp
            }
            return existing
        }

        guard order.generatedFollowUpId == nil else {
            throw MedicalOrderServiceError.duplicateOrderFollowUp
        }
        try validateCAS(order, expectedRevision: expectedOrderRevision)
        guard DomainFieldPolicy.isFinite(plannedDate),
              isTodayOrFuture(plannedDate) else {
            throw MedicalOrderServiceError.invalidPlannedDate
        }
        guard !normalizedItems.isEmpty else {
            throw MedicalOrderServiceError.emptyFollowUpItems
        }
        try validateFollowUpText(
            items: normalizedItems,
            reason: normalizedReason
        )

        let timestamp = now()
        let oldLink = order.generatedFollowUpId
        let oldUpdatedAt = order.updatedAt
        let followUp = FollowUp(
            patientId: patientId,
            sourceOrderId: order.id,
            plannedDate: plannedDate,
            items: normalizedItems,
            reason: normalizedReason,
            reminderEnabled: reminderEnabled,
            createdAt: timestamp
        )
        order.linkGeneratedFollowUp(followUp.id, updatedAt: timestamp)
        context.insert(followUp)
        do {
            try saveAction(context)
            return followUp
        } catch {
            context.rollback()
            order.linkGeneratedFollowUp(oldLink, updatedAt: oldUpdatedAt)
            throw MedicalOrderServiceError.databaseSaveFailed
        }
    }

    @discardableResult
    func undoLastOrder(
        orderId: UUID,
        patientId: UUID,
        expectedRevision: Int
    ) throws -> ContentRevision {
        let order = try scopedOrder(id: orderId, patientId: patientId)
        do {
            return try revisionService.undoLast(
                order,
                expectedRevision: expectedRevision
            )
        } catch let error as ContentRevisionServiceError {
            throw mapRevisionError(error)
        }
    }

    @discardableResult
    func undoLastFollowUp(
        followUpId: UUID,
        patientId: UUID,
        expectedRevision: Int
    ) throws -> ContentRevision {
        let followUp = try scopedFollowUp(
            id: followUpId,
            patientId: patientId
        )
        do {
            return try revisionService.undoLast(
                followUp,
                expectedRevision: expectedRevision
            )
        } catch let error as ContentRevisionServiceError {
            throw mapRevisionError(error)
        }
    }

    private var revisionService: ContentRevisionService {
        ContentRevisionService(context: context, saveAction: saveAction)
    }

    private func normalizedFollowUp(
        _ content: FollowUpEditableContent,
        current: FollowUp
    ) throws -> FollowUpEditableContent {
        var result = content
        result.items = content.items.compactMap {
            MemberIdentity.optionalTrimmed($0)
        }
        result.reason = MemberIdentity.optionalTrimmed(content.reason)
        guard !result.items.isEmpty else {
            throw MedicalOrderServiceError.emptyFollowUpItems
        }
        try validateFollowUpText(
            items: result.items,
            reason: result.reason
        )
        guard DomainFieldPolicy.isFinite(result.plannedDate),
              DomainFieldPolicy.isFinite(result.updatedAt),
              result.completedAt.map(DomainFieldPolicy.isFinite) ?? true else {
            throw MedicalOrderServiceError.invalidDate
        }
        if result.status == .pending {
            let dateWasChanged = result.plannedDate != current.plannedDate
            guard (!dateWasChanged || isTodayOrFuture(result.plannedDate)),
                  result.completedAt == nil else {
                throw MedicalOrderServiceError.invalidCompletionState
            }
        } else {
            guard let completedAt = result.completedAt,
                  completedAt <= now() else {
                throw MedicalOrderServiceError.invalidCompletionState
            }
            result.reminderEnabled = false
        }
        return result
    }

    private func validateFollowUpText(
        items: [String],
        reason: String?
    ) throws {
        guard items.count <= DomainFieldPolicy.listMaximumCount,
              items.allSatisfy({
                  DomainFieldPolicy.isWithinUTF8Limit(
                      $0,
                      maximum: DomainFieldPolicy.listItemMaximumUTF8Bytes
                  )
              }) else {
            throw MedicalOrderServiceError.textTooLong(field: "items")
        }
        guard reason.map({
            DomainFieldPolicy.isWithinUTF8Limit(
                $0,
                maximum: DomainFieldPolicy.noteMaximumUTF8Bytes
            )
        }) ?? true else {
            throw MedicalOrderServiceError.textTooLong(field: "reason")
        }
    }

    private func validateRecordReferences(
        _ content: FollowUpEditableContent,
        patientId: UUID,
        existingContent: FollowUpEditableContent
    ) throws {
        let references = content.bringRecordIds +
            [content.compareRecordId, content.resultRecordId].compactMap { $0 }
        let existingReferences = Set(
            existingContent.bringRecordIds +
                [
                    existingContent.compareRecordId,
                    existingContent.resultRecordId
                ].compactMap { $0 }
        )
        guard references.count <= DomainFieldPolicy.listMaximumCount else {
            throw MedicalOrderServiceError.textTooLong(field: "recordReferences")
        }
        guard Set(content.bringRecordIds).count ==
                content.bringRecordIds.count else {
            throw MedicalOrderServiceError.duplicateRecordReference
        }
        for id in references {
            var descriptor = FetchDescriptor<MedicalRecord>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            guard let record = try context.fetch(descriptor).first else {
                // A previously valid reference can outlive a deleted record.
                // Keep that tombstone stable so editing another field does not
                // force the user to erase historical context.
                if existingReferences.contains(id) {
                    continue
                }
                throw MedicalOrderServiceError.linkedRecordMissing
            }
            guard record.patientId == patientId else {
                throw MedicalOrderServiceError.crossPatientScope
            }
        }
    }

    private func isTodayOrFuture(_ date: Date) -> Bool {
        guard DomainFieldPolicy.isFinite(date) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = businessTimeZone
        return calendar.startOfDay(for: date) >=
            calendar.startOfDay(for: now())
    }

    private func scopedOrder(
        id: UUID,
        patientId: UUID
    ) throws -> MedicalOrder {
        guard let order = try fetchOrder(id: id) else {
            throw MedicalOrderServiceError.orderMissing
        }
        guard order.patientId == patientId else {
            throw MedicalOrderServiceError.crossPatientScope
        }
        guard try fetchPatient(id: patientId) != nil else {
            throw MedicalOrderServiceError.patientMissing
        }
        return order
    }

    private func scopedFollowUp(
        id: UUID,
        patientId: UUID
    ) throws -> FollowUp {
        guard let followUp = try fetchFollowUp(id: id) else {
            throw MedicalOrderServiceError.followUpMissing
        }
        guard followUp.patientId == patientId else {
            throw MedicalOrderServiceError.crossPatientScope
        }
        guard try fetchPatient(id: patientId) != nil else {
            throw MedicalOrderServiceError.patientMissing
        }
        return followUp
    }

    private func validateCAS(
        _ order: MedicalOrder,
        expectedRevision: Int
    ) throws {
        let probe = ModelContext(context.container)
        guard let persisted = probe.model(
            for: order.persistentModelID
        ) as? MedicalOrder else {
            throw MedicalOrderServiceError.orderMissing
        }
        let actual = persisted.contentRevision
        guard expectedRevision == actual,
              order.contentRevision == actual else {
            throw MedicalOrderServiceError.revisionConflict(
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
            throw MedicalOrderServiceError.sourceRecordMissing
        }
        guard record.patientId == patientId else {
            throw MedicalOrderServiceError.crossPatientScope
        }
    }

    private func fetchPatient(id: UUID) throws -> Patient? {
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchOrder(id: UUID) throws -> MedicalOrder? {
        var descriptor = FetchDescriptor<MedicalOrder>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchFollowUp(id: UUID) throws -> FollowUp? {
        var descriptor = FetchDescriptor<FollowUp>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchFollowUp(sourceOrderId: UUID) throws -> FollowUp? {
        var descriptor = FetchDescriptor<FollowUp>(
            predicate: #Predicate {
                $0.sourceOrderId == sourceOrderId
            }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw MedicalOrderServiceError.duplicateOrderFollowUp
        }
        return matches.first
    }

    private func mapRevisionError(
        _ error: ContentRevisionServiceError
    ) -> MedicalOrderServiceError {
        switch error {
        case let .revisionConflict(expected, actual):
            .revisionConflict(expected: expected, actual: actual)
        case .noChanges:
            .noChanges
        default:
            .databaseSaveFailed
        }
    }
}
