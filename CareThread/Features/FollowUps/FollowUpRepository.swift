import Foundation
import SwiftData

enum FollowUpRepositoryError: Error, Equatable {
    case patientMissing
    case invalidForm
    case linkedRecordMissing
    case crossPatientScope
    case saveFailed
}
@MainActor
struct FollowUpRepository {
    let context: ModelContext
    var now: () -> Date = Date.init
    var calendar: Calendar = .current

    func fetch(patientID: UUID) throws -> [FollowUp] {
        var descriptor = FetchDescriptor<FollowUp>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\.plannedDate)]
        )
        descriptor.fetchLimit = M4M5QueryLimit.standard
        return try context.fetch(descriptor)
    }

    func fetchRecords(patientID: UUID) throws -> [MedicalRecord] {
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\.eventDate, order: .reverse)]
        )
        descriptor.fetchLimit = M4M5QueryLimit.recordPicker
        return try context.fetch(descriptor)
    }

    func create(
        patientID: UUID,
        state: FollowUpFormState
    ) throws -> FollowUp {
        guard state.validation(now: now(), calendar: calendar) == .valid else {
            throw FollowUpRepositoryError.invalidForm
        }
        var patientDescriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == patientID }
        )
        patientDescriptor.fetchLimit = 1
        guard try context.fetch(patientDescriptor).first != nil else {
            throw FollowUpRepositoryError.patientMissing
        }
        try validateReferences(
            state.bringRecordIDs.union(
                state.compareRecordID.map { [$0] } ?? []
            ),
            patientID: patientID
        )
        let followUp = FollowUp(
            patientId: patientID,
            plannedDate: state.plannedDate,
            items: state.items,
            reason: state.reason.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nilIfEmpty,
            bringRecordIds: Array(state.bringRecordIDs).sorted {
                $0.uuidString < $1.uuidString
            },
            compareRecordId: state.compareRecordID,
            reminderEnabled: state.reminderEnabled,
            createdAt: now()
        )
        context.insert(followUp)
        do {
            try context.save()
            AppLog.data.info("Created standalone follow-up for selected member")
            return followUp
        } catch {
            context.rollback()
            AppLog.data.error("Standalone follow-up save failed")
            throw FollowUpRepositoryError.saveFailed
        }
    }

    func completeOnly(_ followUp: FollowUp) throws {
        var content = followUp.editableContent()
        content.status = .completed
        content.completedAt = now()
        content.reminderEnabled = false
        content.updatedAt = now()
        do {
            _ = try MedicalOrderService(
                context: context,
                now: now
            ).editFollowUp(
                followUpId: followUp.id,
                patientId: followUp.patientId,
                content: content,
                changedFieldKeys: [
                    "status", "completedAt", "reminderEnabled"
                ],
                expectedRevision: followUp.contentRevision
            )
            AppLog.data.info("Marked follow-up completed")
        } catch {
            AppLog.data.error("Follow-up completion failed")
            throw FollowUpRepositoryError.saveFailed
        }
    }

    func bindCalendarEvent(
        followUp: FollowUp,
        eventIdentifier: String
    ) throws {
        let reminderID = followUp.id
        var descriptor = FetchDescriptor<AppleReminderBinding>(
            predicate: #Predicate {
                $0.reminderId == reminderID &&
                    $0.destinationRawValue == "systemCalendar"
            }
        )
        descriptor.fetchLimit = 1
        let binding: AppleReminderBinding
        if let existing = try context.fetch(descriptor).first {
            existing.updateIdentifiers(
                localNotificationIdentifier: nil,
                calendarEventIdentifier: eventIdentifier
            )
            binding = existing
        } else {
            binding = AppleReminderBinding(
                patientId: followUp.patientId,
                reminderId: followUp.id,
                destination: .systemCalendar,
                calendarEventIdentifier: eventIdentifier
            )
            context.insert(binding)
        }
        do {
            try context.save()
            AppLog.data.info("Bound system Calendar identifier separately")
        } catch {
            context.rollback()
            throw FollowUpRepositoryError.saveFailed
        }
    }

    private func validateReferences(
        _ ids: Set<UUID>,
        patientID: UUID
    ) throws {
        for id in ids {
            var descriptor = FetchDescriptor<MedicalRecord>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            guard let record = try context.fetch(descriptor).first else {
                throw FollowUpRepositoryError.linkedRecordMissing
            }
            guard record.patientId == patientID else {
                throw FollowUpRepositoryError.crossPatientScope
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension M4M5QueryLimit {
    static let recordPicker = 100
}
