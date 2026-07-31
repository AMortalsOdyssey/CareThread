import Foundation
import SwiftData

struct CaptureNameEvidence: Equatable {
    var outcome: RecordAssignmentOutcome
    var detectedName: String?
    var reliableNormalizedNames: Set<String>
}

enum CaptureNameEvidenceAggregator {
    static func evaluate(
        draft: CaptureDraft,
        frozenPatient: Patient
    ) throws -> CaptureNameEvidence {
        guard !draft.pages.isEmpty else { throw CaptureGroupingError.emptyDocument }

        var seenPageIndexes = Set<Int>()
        var namesByNormalizedValue: [String: String] = [:]
        for page in draft.pages {
            guard page.patientId == draft.patientId else {
                throw CaptureGroupingError.wrongPatient
            }
            guard page.batchId == draft.batchId else {
                throw CaptureGroupingError.wrongBatch
            }
            guard page.draftId == draft.id else {
                throw CaptureGroupingError.wrongDocument
            }
            guard page.ocrGeneration == draft.generation else {
                throw CaptureGroupingError.generationMismatch
            }
            guard [.recognized, .noEvidence].contains(page.ocrStatus) else {
                throw CaptureGroupingError.ocrIncomplete
            }
            guard seenPageIndexes.insert(page.pageIndex).inserted else {
                throw CaptureGroupingError.duplicatePageIndex
            }
            for candidate in page.detectedNameCandidates where candidate.isReliable {
                guard let displayName = MemberIdentity.optionalTrimmed(candidate.name) else { continue }
                let normalized = MemberIdentity.normalize(displayName)
                guard !normalized.isEmpty else { continue }
                namesByNormalizedValue[normalized] = displayName
            }
        }
        guard seenPageIndexes == Set(0..<draft.pages.count) else {
            throw CaptureGroupingError.duplicatePageIndex
        }

        let normalizedNames = Set(namesByNormalizedValue.keys)
        guard !normalizedNames.isEmpty else {
            return CaptureNameEvidence(
                outcome: .noEvidence,
                detectedName: nil,
                reliableNormalizedNames: []
            )
        }
        guard normalizedNames.count == 1, let normalized = normalizedNames.first else {
            return CaptureNameEvidence(
                outcome: .ambiguous,
                detectedName: namesByNormalizedValue.values.sorted().joined(separator: "、"),
                reliableNormalizedNames: normalizedNames
            )
        }
        let outcome: RecordAssignmentOutcome = frozenPatient.normalizedAliases.contains(normalized)
            ? .match
            : .mismatch
        return CaptureNameEvidence(
            outcome: outcome,
            detectedName: namesByNormalizedValue[normalized],
            reliableNormalizedNames: normalizedNames
        )
    }
}

struct CaptureCommitRequest {
    var draftId: UUID
    var expectedGeneration: Int
    var expectedOutcome: RecordAssignmentOutcome
    var decision: AssignmentDecision
    var overrideReason: String?
    var assignedPatientId: UUID
    var record: MedicalRecord
    var engineIdentifier: String
    var engineVersion: String?
}

enum CaptureCommitError: Error, Equatable {
    case draftMissing
    case batchMissing
    case frozenPatientMissing
    case assignedPatientMissing
    case generationMismatch
    case invalidCaptureDocument
    case evidenceMismatch
    case invalidDecision
    case rejectedDecision
    case invalidAssignedMember
    case invalidRecordSource
    case graphInvalid
    case duplicateAttachmentSHA
    case databaseSaveFailed
}

@MainActor
final class CaptureCommitService {
    typealias SaveAction = @MainActor (ModelContext) throws -> Void

    private let context: ModelContext
    private let saveAction: SaveAction

    init(
        context: ModelContext,
        saveAction: @escaping SaveAction = { try $0.save() }
    ) {
        self.context = context
        self.saveAction = saveAction
    }

    /// Performs the final generation/evidence/tenant/graph checks and inserts
    /// the record plus immutable audit in one SwiftData save.
    func commit(_ request: CaptureCommitRequest) throws -> RecordAssignmentAudit {
        guard let draft = try fetchDraft(id: request.draftId) else {
            throw CaptureCommitError.draftMissing
        }
        guard draft.generation == request.expectedGeneration else {
            throw CaptureCommitError.generationMismatch
        }
        guard let batch = try fetchBatch(id: draft.batchId),
              batch.patientId == draft.patientId,
              draft.batch == nil || draft.batch === batch else {
            throw CaptureCommitError.batchMissing
        }
        guard let frozenPatient = try fetchPatient(id: draft.patientId) else {
            throw CaptureCommitError.frozenPatientMissing
        }
        guard let assignedPatient = try fetchPatient(id: request.assignedPatientId) else {
            throw CaptureCommitError.assignedPatientMissing
        }

        let evidence: CaptureNameEvidence
        do {
            evidence = try CaptureNameEvidenceAggregator.evaluate(
                draft: draft,
                frozenPatient: frozenPatient
            )
        } catch CaptureGroupingError.generationMismatch {
            AppLog.data.warning("Capture evidence generation or scope validation failed")
            throw CaptureCommitError.generationMismatch
        } catch {
            AppLog.data.warning("Capture document grouping validation failed")
            throw CaptureCommitError.invalidCaptureDocument
        }
        guard evidence.outcome == request.expectedOutcome else {
            throw CaptureCommitError.evidenceMismatch
        }
        guard request.decision != .rejected else {
            throw CaptureCommitError.rejectedDecision
        }
        do {
            try RecordAssignmentPolicy.validate(
                outcome: evidence.outcome,
                decision: request.decision,
                overrideReason: request.overrideReason
            )
        } catch {
            throw CaptureCommitError.invalidDecision
        }
        try validateAssignment(
            evidence: evidence,
            decision: request.decision,
            frozenPatientId: draft.patientId,
            assignedPatient: assignedPatient
        )

        guard request.record.patientId == assignedPatient.id else {
            throw CaptureCommitError.invalidAssignedMember
        }
        guard [.camera, .photo, .file].contains(request.record.sourceType) else {
            throw CaptureCommitError.invalidRecordSource
        }
        do {
            try request.record.validateGraph()
        } catch {
            throw CaptureCommitError.graphInvalid
        }
        try validateNoExactAttachmentDuplicate(
            record: request.record,
            patientID: assignedPatient.id
        )

        let audit = RecordAssignmentAudit(
            capturedForPatientId: draft.patientId,
            assignedPatientId: assignedPatient.id,
            draftId: draft.id,
            recordId: request.record.id,
            detectedName: evidence.detectedName,
            outcome: evidence.outcome,
            decision: request.decision,
            overrideReason: request.overrideReason,
            engineIdentifier: request.engineIdentifier,
            engineVersion: request.engineVersion
        )
        let batchState = batch.state
        let remainingDocumentCount = max(0, batch.drafts.count - 1)
        batch.markDocumentCommitted(remainingDocumentCount: remainingDocumentCount)
        context.insert(request.record)
        context.insert(audit)
        context.delete(draft)
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            batch.restoreState(batchState)
            AppLog.data.error("Capture commit database save failed")
            throw CaptureCommitError.databaseSaveFailed
        }
        AppLog.userAction.info(
            "Committed captured record \(request.record.id.uuidString, privacy: .private(mask: .hash))"
        )
        return audit
    }

    /// This transaction-boundary guard prevents a future capture UI, a second
    /// window, or an elder-mode path from bypassing the preflight duplicate
    /// check. Only the final assigned member is queried; another member's
    /// attachment hashes are intentionally invisible here.
    private func validateNoExactAttachmentDuplicate(
        record: MedicalRecord,
        patientID: UUID
    ) throws {
        let incomingHashes = record.attachments.map {
            $0.sha256.lowercased()
        }
        guard Set(incomingHashes).count == incomingHashes.count else {
            throw CaptureCommitError.duplicateAttachmentSHA
        }
        guard !incomingHashes.isEmpty else { return }
        var descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate { $0.patientId == patientID }
        )
        descriptor.includePendingChanges = true
        let currentContextHashes = Set(
            try context.fetch(descriptor).map {
                $0.sha256.lowercased()
            }
        )
        // Probe persisted state through a fresh context so another scene's
        // committed attachment cannot be hidden by this context's cache.
        let probeContext = ModelContext(context.container)
        descriptor.includePendingChanges = false
        let persistedHashes = Set(
            try probeContext.fetch(descriptor).map {
                $0.sha256.lowercased()
            }
        )
        let existingHashes = currentContextHashes.union(persistedHashes)
        guard incomingHashes.allSatisfy({ !existingHashes.contains($0) }) else {
            throw CaptureCommitError.duplicateAttachmentSHA
        }
    }

    private func validateAssignment(
        evidence: CaptureNameEvidence,
        decision: AssignmentDecision,
        frozenPatientId: UUID,
        assignedPatient: Patient
    ) throws {
        switch decision {
        case .acceptedMatch, .acceptedWithoutNameEvidence,
             .acceptedAfterNameRecognitionOverride:
            guard assignedPatient.id == frozenPatientId else {
                throw CaptureCommitError.invalidAssignedMember
            }
        case .switchedMember:
            guard assignedPatient.id != frozenPatientId else {
                throw CaptureCommitError.invalidAssignedMember
            }
            guard !evidence.reliableNormalizedNames.isDisjoint(
                with: Set(assignedPatient.normalizedAliases)
            ) else {
                throw CaptureCommitError.invalidAssignedMember
            }
        case .rejected:
            throw CaptureCommitError.rejectedDecision
        }
    }

    private func fetchDraft(id: UUID) throws -> CaptureDraft? {
        var descriptor = FetchDescriptor<CaptureDraft>(
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

    private func fetchBatch(id: UUID) throws -> ImportBatch? {
        var descriptor = FetchDescriptor<ImportBatch>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
