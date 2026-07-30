import Foundation
import SwiftData

@MainActor
final class RecordRepository {
    private let context: ModelContext
    private let vaultStore: VaultStore?

    init(context: ModelContext, vaultStore: VaultStore? = nil) {
        self.context = context
        self.vaultStore = vaultStore
    }

    func insert(_ record: MedicalRecord) throws {
        AppLog.userAction.info("Insert medical record \(record.id.uuidString, privacy: .public)")
        context.insert(record)
        try context.save()
    }

    func delete(_ record: MedicalRecord) throws {
        AppLog.userAction.info("Delete medical record \(record.id.uuidString, privacy: .public)")
        let paths = record.attachments.flatMap { attachment in
            [attachment.fileName, attachment.originalFileName].compactMap { $0 }
        }
        context.delete(record)
        try context.save()
        vaultStore?.delete(relativePaths: paths)
    }

    func adjustMedication(
        _ medication: Medication,
        newDose: Double,
        effectiveDate: Date
    ) throws -> Medication {
        medication.endDate = effectiveDate
        medication.isLongTerm = false
        let replacement = Medication(
            patientId: medication.patientId,
            name: medication.name,
            doseValue: newDose,
            doseUnit: medication.doseUnit,
            frequency: medication.frequency,
            weeklyCount: medication.weeklyCount,
            usageNotes: medication.usageNotes,
            startDate: effectiveDate,
            isLongTerm: true,
            hospital: medication.hospital,
            department: medication.department,
            linkedDiagnosis: medication.linkedDiagnosis,
            caution: medication.caution,
            sourceRecordId: medication.sourceRecordId,
            previousVersionId: medication.id,
            reminderEnabled: medication.reminderEnabled,
            reminderTimes: medication.reminderTimes
        )
        context.insert(replacement)
        try context.save()
        AppLog.userAction.info("Adjusted medication \(medication.id.uuidString, privacy: .public)")
        return replacement
    }
}

