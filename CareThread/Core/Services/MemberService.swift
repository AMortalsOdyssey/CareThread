import Foundation
import SwiftData

protocol MemberVaultProvisioning: AnyObject {
    /// Must complete synchronously and clean up its own partial work on throw.
    func provisionVault(for patientId: UUID) throws
    func rollbackVault(for patientId: UUID)
    /// Permanent member deletion uses the same tenant-root removal primitive.
    func deleteVault(for patientId: UUID)
}

extension MemberVaultProvisioning {
    func deleteVault(for patientId: UUID) {
        rollbackVault(for: patientId)
    }
}

protocol SelectedMemberWriting: AnyObject {
    var selectedPatientId: UUID? { get set }
}

final class NoopMemberVaultProvisioner: MemberVaultProvisioning {
    func provisionVault(for patientId: UUID) throws {}
    func rollbackVault(for patientId: UUID) {}
}

final class InMemorySelectedMemberStore: SelectedMemberWriting {
    var selectedPatientId: UUID?
}

enum MemberServiceError: Error, Equatable {
    case maximumReached(limit: Int)
    case memberNotFound
    case invalidProfile(PatientProfileValidationError)
    case vaultProvisionFailed
    case databaseSaveFailed
}

@MainActor
final class MemberService {
    typealias SaveAction = @MainActor (ModelContext) throws -> Void

    private let context: ModelContext
    private let vaultProvisioner: MemberVaultProvisioning
    private let selectionStore: SelectedMemberWriting
    private let saveAction: SaveAction

    init(
        context: ModelContext,
        vaultProvisioner: MemberVaultProvisioning,
        selectionStore: SelectedMemberWriting,
        saveAction: @escaping SaveAction = { try $0.save() }
    ) {
        self.context = context
        self.vaultProvisioner = vaultProvisioner
        self.selectionStore = selectionStore
        self.saveAction = saveAction
    }

    /// Count → insert → synchronous Vault provisioning → save is one MainActor
    /// critical section with no suspension point.
    func createMember(
        id: UUID = UUID(),
        displayName: String,
        reportName: String? = nil,
        aliases: [String] = [],
        birthDate: Date? = nil,
        gender: String? = nil,
        conditions: [String] = [],
        allergies: [String] = [],
        histories: [HistoryItem] = [],
        careQuestions: [CareQuestion] = [],
        selectAfterCreation: Bool = true
    ) throws -> Patient {
        let existingCount = try context.fetchCount(FetchDescriptor<Patient>())
        do {
            try MemberLimitPolicy.validateAddition(existingCount: existingCount)
        } catch MemberLimitPolicyError.maximumReached(let limit) {
            AppLog.data.warning("Rejected member creation because limit \(limit) is reached")
            throw MemberServiceError.maximumReached(limit: limit)
        }
        do {
            try PatientProfilePolicy.validateIdentity(
                displayName: displayName,
                reportName: reportName,
                aliases: aliases,
                birthDate: birthDate,
                gender: gender
            )
            try PatientProfilePolicy.validateHealthLists(
                conditions: conditions,
                allergies: allergies,
                histories: histories
            )
            try PatientProfilePolicy.validateQuestions(careQuestions)
        } catch let error as PatientProfileValidationError {
            AppLog.data.warning("Rejected invalid member profile")
            throw MemberServiceError.invalidProfile(error)
        }

        let patient = Patient(
            id: id,
            displayName: displayName,
            reportName: reportName,
            aliases: aliases,
            birthDate: birthDate,
            gender: gender,
            conditions: conditions,
            allergies: allergies,
            histories: histories,
            careQuestions: careQuestions
        )
        context.insert(patient)

        do {
            try vaultProvisioner.provisionVault(for: id)
        } catch {
            context.rollback()
            vaultProvisioner.rollbackVault(for: id)
            AppLog.data.error("Member Vault provisioning failed")
            throw MemberServiceError.vaultProvisionFailed
        }

        do {
            try saveAction(context)
        } catch {
            context.rollback()
            vaultProvisioner.rollbackVault(for: id)
            AppLog.data.error("Member database save failed")
            throw MemberServiceError.databaseSaveFailed
        }

        if selectAfterCreation {
            selectionStore.selectedPatientId = id
        }
        AppLog.userAction.info(
            "Created member \(id.uuidString, privacy: .private(mask: .hash))"
        )
        return patient
    }

    /// Changes only the active selection. No clinical row or Vault content is
    /// copied between members.
    func selectMember(id: UUID) throws {
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard !(try context.fetch(descriptor)).isEmpty else {
            AppLog.data.warning("Rejected selection of missing member")
            throw MemberServiceError.memberNotFound
        }
        selectionStore.selectedPatientId = id
        AppLog.userAction.info(
            "Selected member \(id.uuidString, privacy: .private(mask: .hash))"
        )
    }

    /// Permanently removes one member's database rows and Vault tenant root.
    ///
    /// Database deletion is saved before the Vault is removed. A failed save
    /// rolls the ModelContext back and leaves the Vault and current selection
    /// untouched. Other members are never included in a deletion predicate.
    @discardableResult
    func deleteMember(id: UUID) throws -> UUID? {
        let patients = try context.fetch(FetchDescriptor<Patient>())
        guard let target = patients.first(where: { $0.id == id }) else {
            AppLog.data.warning("Rejected deletion of missing member")
            throw MemberServiceError.memberNotFound
        }
        let survivors = patients
            .filter { $0.id != id }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        let survivorIDs = Set(survivors.map(\.id))
        let selectionAfterDeletion: UUID?
        if let current = selectionStore.selectedPatientId,
           survivorIDs.contains(current) {
            selectionAfterDeletion = current
        } else {
            selectionAfterDeletion = survivors.first?.id
        }

        try deletePatientScopedRows(patientID: id)
        context.delete(target)
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            AppLog.data.error("Member database deletion failed")
            throw MemberServiceError.databaseSaveFailed
        }

        vaultProvisioner.deleteVault(for: id)
        selectionStore.selectedPatientId = selectionAfterDeletion
        AppLog.userAction.info(
            "Deleted member \(id.uuidString, privacy: .private(mask: .hash))"
        )
        return selectionAfterDeletion
    }

    private func deletePatientScopedRows(patientID: UUID) throws {
        try delete(
            ContentRevision.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            AppleReminderBinding.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            ReminderSchedule.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            RecordAssignmentAudit.self,
            predicate: #Predicate {
                $0.assignedPatientId == patientID
                    || (
                        $0.assignedPatientId == nil
                            && $0.capturedForPatientId == patientID
                    )
            }
        )
        try delete(
            CapturePage.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            CaptureDraft.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            ImportBatch.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            RecordTag.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            LabMeasurement.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            Attachment.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            FollowUp.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            MedicalOrder.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            Medication.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
        try delete(
            MedicalRecord.self,
            predicate: #Predicate { $0.patientId == patientID }
        )
    }

    private func delete<T: PersistentModel>(
        _ type: T.Type,
        predicate: Predicate<T>
    ) throws {
        for value in try context.fetch(
            FetchDescriptor<T>(predicate: predicate)
        ) {
            context.delete(value)
        }
    }
}
