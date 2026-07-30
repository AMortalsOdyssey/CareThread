import Foundation
import SwiftData

enum RecordRepositoryError: Error, Equatable {
    case manualInsertOnly
    case patientMissing
    case invalidGraph
    case attachmentCleanupUnavailable
}

@MainActor
protocol AttachmentFileDeleting {
    /// Called only after the database delete has committed. Implementations
    /// must log file-system failures for later orphan cleanup and must not
    /// attempt to roll back the committed database transaction.
    func deleteAttachmentFiles(
        derivedRelativePaths: Set<String>,
        unreferencedOriginalRelativePaths: Set<String>
    )
}

@MainActor
final class RecordRepository {
    private let context: ModelContext
    private let fileDeletion: AttachmentFileDeleting?

    init(
        context: ModelContext,
        fileDeletion: AttachmentFileDeleting? = nil
    ) {
        self.context = context
        self.fileDeletion = fileDeletion
    }

    /// Compatibility-only bridge for legacy VaultStore tests.
    convenience init(context: ModelContext, vaultStore: VaultStore) {
        self.init(context: context, fileDeletion: vaultStore)
    }

    func insert(_ record: MedicalRecord) throws {
        guard record.sourceType == .manual else {
            AppLog.data.warning("Rejected non-manual record through manual repository")
            throw RecordRepositoryError.manualInsertOnly
        }
        guard try patientExists(id: record.patientId) else {
            throw RecordRepositoryError.patientMissing
        }
        do {
            try record.validateGraph()
        } catch {
            throw RecordRepositoryError.invalidGraph
        }
        AppLog.userAction.info(
            "Insert medical record \(record.id.uuidString, privacy: .private(mask: .hash))"
        )
        context.insert(record)
        try context.save()
    }

    func delete(_ record: MedicalRecord) throws {
        AppLog.userAction.info(
            "Delete medical record \(record.id.uuidString, privacy: .private(mask: .hash))"
        )
        let originals = Set(record.attachments.map(\.originalRelativePath))
        let derived = Set(record.attachments.compactMap(\.derivedRelativePath))
        guard originals.isEmpty || fileDeletion != nil else {
            AppLog.vault.error(
                "Rejected record delete because attachment cleanup is unavailable"
            )
            throw RecordRepositoryError.attachmentCleanupUnavailable
        }
        context.delete(record)
        try context.save()
        cleanupAttachmentFiles(originals: originals, derived: derived)
    }

    func adjustMedication(
        _ medication: Medication,
        newDose: Double,
        effectiveDate: Date
    ) throws -> Medication {
        try MedicationService(context: context).adjustDose(
            medicationId: medication.id,
            patientId: medication.patientId,
            expectedRevision: medication.contentRevision,
            doseValue: newDose,
            doseUnit: medication.doseUnit,
            effectiveAt: effectiveDate
        )
    }

    func replaceGraph(
        of record: MedicalRecord,
        attachments: [Attachment],
        measurements: [LabMeasurement],
        tags: [RecordTag]
    ) throws {
        let replacementAttachmentIDs = Set(attachments.map(\.id))
        let attachmentsToRemove = record.attachments.filter {
            !replacementAttachmentIDs.contains($0.id)
        }
        guard attachmentsToRemove.isEmpty || fileDeletion != nil else {
            AppLog.vault.error(
                "Rejected graph replacement because attachment cleanup is unavailable"
            )
            throw RecordRepositoryError.attachmentCleanupUnavailable
        }
        let removedAttachments: [Attachment]
        let removedMeasurements: [LabMeasurement]
        let removedTags: [RecordTag]
        do {
            removedAttachments = try record.replaceAttachments(with: attachments)
            removedMeasurements = try record.replaceMeasurements(with: measurements)
            removedTags = try record.replaceTags(with: tags)
            try record.validateGraph()
        } catch {
            context.rollback()
            throw RecordRepositoryError.invalidGraph
        }
        let removedOriginals = Set(
            removedAttachments.map(\.originalRelativePath)
        )
        let removedDerived = Set(
            removedAttachments.compactMap(\.derivedRelativePath)
        )
        removedAttachments.forEach(context.delete)
        removedMeasurements.forEach(context.delete)
        removedTags.forEach(context.delete)
        try context.save()
        cleanupAttachmentFiles(
            originals: removedOriginals,
            derived: removedDerived
        )
    }

    private func patientExists(id: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    /// The database commit happens first. Originals are deleted only after a
    /// post-commit reference check; previews are attachment-specific and can
    /// be scheduled immediately. A missing executor is rejected before the
    /// database mutation, so an attachment can never become a silent orphan.
    private func cleanupAttachmentFiles(
        originals: Set<String>,
        derived: Set<String>
    ) {
        guard !originals.isEmpty || !derived.isEmpty else { return }
        guard let fileDeletion else {
            // Public mutators guard this before committing. Keep a defensive
            // log in case a future call site bypasses that contract.
            AppLog.vault.error(
                "Attachment cleanup executor missing after database commit"
            )
            return
        }
        var unreferencedOriginals = Set<String>()
        for path in originals {
            do {
                var descriptor = FetchDescriptor<Attachment>(
                    predicate: #Predicate { $0.originalRelativePath == path }
                )
                descriptor.fetchLimit = 1
                if try context.fetch(descriptor).isEmpty {
                    unreferencedOriginals.insert(path)
                }
            } catch {
                AppLog.vault.error(
                    "Attachment original reference verification failed for \(path, privacy: .private(mask: .hash)); retained for retry"
                )
            }
        }
        fileDeletion.deleteAttachmentFiles(
            derivedRelativePaths: derived,
            unreferencedOriginalRelativePaths: unreferencedOriginals
        )
    }
}
