import Foundation
import SwiftData

enum ElderCaptureError: Error, Equatable {
    case noPages
    case tooManyPages
    case invalidImage
    case memberMissing
    case identityRequiresStandardReview
    case duplicateRequiresStandardReview
    case safetyReviewRequiresStandard
    case persistenceFailed
}

struct ElderCaptureRequest {
    let patientID: UUID
    let batchID: UUID
    let stagedAssets: [StagedCaptureAsset]
    let source: M3CaptureSource
    let typeChoice: ElderCaptureTypeChoice
    let eventDate: Date
}

struct ElderCaptureResult {
    let record: MedicalRecord
    let ocrWasEmpty: Bool
}

@MainActor
final class ElderCaptureService {
    private let context: ModelContext
    private let vault: CaptureVaultService

    init(context: ModelContext, vault: CaptureVaultService) {
        self.context = context
        self.vault = vault
    }

    func save(_ request: ElderCaptureRequest) async throws -> ElderCaptureResult {
        var hasRecoverableDraft = false
        do {
            guard !request.stagedAssets.isEmpty else {
                throw ElderCaptureError.noPages
            }
            guard request.stagedAssets.count <= 50 else {
                throw ElderCaptureError.tooManyPages
            }
            guard request.stagedAssets.allSatisfy({
                $0.batchID == request.batchID
            }), Set(request.stagedAssets.map(\.id)).count
                == request.stagedAssets.count else {
                throw ElderCaptureError.invalidImage
            }
            let journal = try vault.journal(batchID: request.batchID)
            guard journal.assets == request.stagedAssets else {
                throw ElderCaptureError.invalidImage
            }
            guard try memberExists(request.patientID) else {
                throw ElderCaptureError.memberMissing
            }
            let persistent = try makePersistentDraft(
                request: request,
                batchID: request.batchID,
                assets: request.stagedAssets
            )
            hasRecoverableDraft = true
            let outputs = try await recognize(
                draft: persistent.draft,
                pages: persistent.pages,
                assets: request.stagedAssets,
                source: request.source
            )
            // Persist the OCR draft before either identity or duplicate review.
            // Elder mode never destroys a user's only captured copy merely
            // because a higher-risk decision belongs in standard mode.
            try context.save()
            let textByAssetID = Dictionary(
                uniqueKeysWithValues: zip(request.stagedAssets, outputs).map {
                    ($0.id, $1.text)
                }
            )
            if try await CaptureDuplicateDetectionService(
                context: context,
                vault: vault
            ).scan(
                patientID: request.patientID,
                stagedAssets: request.stagedAssets,
                ocrTextByAssetID: textByAssetID
            ) != nil {
                AppLog.userAction.warning(
                    "Elder capture retained as draft because duplicate review is required"
                )
                throw ElderCaptureError.duplicateRequiresStandardReview
            }
            let evidence = try CaptureNameEvidenceAggregator.evaluate(
                draft: persistent.draft,
                frozenPatient: persistent.patient
            )
            guard [.match, .noEvidence].contains(evidence.outcome) else {
                AppLog.userAction.warning(
                    "Elder capture retained as draft because identity evidence needs review"
                )
                throw ElderCaptureError.identityRequiresStandardReview
            }
            return try commit(
                request: request,
                draft: persistent.draft,
                evidence: evidence,
                assets: request.stagedAssets,
                outputs: outputs
            )
        } catch ElderCaptureError.identityRequiresStandardReview {
            throw ElderCaptureError.identityRequiresStandardReview
        } catch ElderCaptureError.duplicateRequiresStandardReview {
            throw ElderCaptureError.duplicateRequiresStandardReview
        } catch ElderCaptureError.safetyReviewRequiresStandard {
            throw ElderCaptureError.safetyReviewRequiresStandard
        } catch is CancellationError {
            guard !hasRecoverableDraft else {
                AppLog.vault.warning(
                    "Cancelled elder capture retained as a recoverable draft"
                )
                throw ElderCaptureError.safetyReviewRequiresStandard
            }
            cleanupFailedRequest(request)
            throw CancellationError()
        } catch let error as ElderCaptureError {
            guard !hasRecoverableDraft else {
                AppLog.vault.warning(
                    "Elder capture safety check failed; draft retained for standard review"
                )
                throw ElderCaptureError.safetyReviewRequiresStandard
            }
            cleanupFailedRequest(request)
            throw error
        } catch {
            guard !hasRecoverableDraft else {
                AppLog.vault.error(
                    "Elder capture failed after draft persistence; original retained"
                )
                throw ElderCaptureError.safetyReviewRequiresStandard
            }
            cleanupFailedRequest(request)
            AppLog.vault.error(
                "Elder capture failed: \(error.localizedDescription)"
            )
            throw ElderCaptureError.persistenceFailed
        }
    }

    private func memberExists(_ id: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func cleanupFailedRequest(_ request: ElderCaptureRequest) {
        context.rollback()
        do {
            let batchID = request.batchID
            var descriptor = FetchDescriptor<ImportBatch>(
                predicate: #Predicate { $0.id == batchID }
            )
            descriptor.fetchLimit = 1
            if let batch = try context.fetch(descriptor).first {
                context.delete(batch)
                try context.save()
            }
            try vault.discardBatch(batchID)
            AppLog.vault.info("Cleaned failed elder capture staging batch")
        } catch {
            AppLog.vault.error(
                "Failed elder capture left a recoverable staging batch"
            )
        }
    }

    private func makePersistentDraft(
        request: ElderCaptureRequest,
        batchID: UUID,
        assets: [StagedCaptureAsset]
    ) throws -> (patient: Patient, draft: CaptureDraft, pages: [CapturePage]) {
        let patientID = request.patientID
        var patientDescriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == patientID }
        )
        patientDescriptor.fetchLimit = 1
        guard let patient = try context.fetch(patientDescriptor).first else {
            throw ElderCaptureError.memberMissing
        }
        let batch = ImportBatch(
            id: batchID,
            patientId: request.patientID,
            sourceType: request.source.sourceType
        )
        let draft = CaptureDraft(
            patientId: request.patientID,
            batchId: batchID,
            documentIndex: 0,
            sourceType: request.source.sourceType,
            selectedDate: request.eventDate,
            batch: batch
        )
        try batch.bindDraft(draft)
        context.insert(batch)
        context.insert(draft)
        let pages = try assets.enumerated().map { index, asset in
            let page = CapturePage(
                patientId: request.patientID,
                batchId: batchID,
                draftId: draft.id,
                sourceOrder: index,
                pageIndex: index,
                stagingRelativePath: asset.originalRelativePath
            )
            try draft.bindPage(page)
            context.insert(page)
            return page
        }
        try context.save()
        AppLog.userAction.info(
            "Elder capture staged \(pages.count) immutable source pages"
        )
        return (patient, draft, pages)
    }

    private func recognize(
        draft: CaptureDraft,
        pages: [CapturePage],
        assets: [StagedCaptureAsset],
        source: M3CaptureSource
    ) async throws -> [M3RecognitionOutput] {
        var outputs: [M3RecognitionOutput] = []
        for index in assets.indices {
            try Task.checkCancellation()
            let asset = assets[index]
            let pageAsset = M3CapturePageAsset(
                stagedAssetID: asset.id,
                batchID: asset.batchID,
                displayName: asset.displayName,
                relativePath: asset.originalRelativePath,
                previewRelativePath: asset.previewRelativePath,
                kind: asset.kind,
                sourceSessionID: asset.batchID.uuidString,
                sourceOrder: index,
                captureSource: source
            )
            let output: M3RecognitionOutput
            do {
                output = try await M3CaptureRecognitionPipeline.recognize(
                    page: pageAsset,
                    pageIndex: index,
                    vault: vault
                )
            } catch {
                AppLog.extraction.warning(
                    "Elder OCR returned no evidence for page \(index)"
                )
                output = M3RecognitionOutput(
                    text: "",
                    averageConfidence: 0,
                    names: [],
                    extraction: .empty
                )
            }
            try pages[index].applyOCR(
                generation: draft.generation,
                status: output.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty ? .noEvidence : .recognized,
                text: output.text,
                detectedNameCandidates: output.names,
                hospitalSuggestion: output.extraction.hospital,
                dateSuggestion: output.extraction.eventDate,
                titleSuggestion: output.extraction.title
            )
            outputs.append(output)
        }
        return outputs
    }

    private func commit(
        request: ElderCaptureRequest,
        draft: CaptureDraft,
        evidence: CaptureNameEvidence,
        assets: [StagedCaptureAsset],
        outputs: [M3RecognitionOutput]
    ) throws -> ElderCaptureResult {
        let aggregateText = outputs.map(\.text).joined(separator: "\n")
        let aggregate = ExtractionEngine().extract(
            aggregateText,
            today: Date(),
            engineIdentifier: VisionOCREngine().identifier
        )
        let machineType = outputs
            .map(\.extraction.type)
            .first(where: { $0 != .other }) ?? aggregate.type
        let resolvedType = ElderCaptureTypePolicy.resolvedType(
            choice: request.typeChoice,
            machineType: machineType
        )
        let recordID = UUID()
        var finalized: [FinalizedCaptureAsset] = []
        do {
            finalized = try assets.map {
                try vault.finalize(
                    asset: $0,
                    patientID: request.patientID,
                    recordID: recordID
                )
            }
            let attachments = try finalized.enumerated().map { index, final in
                try Attachment.verified(
                    id: final.staged.id,
                    patientId: request.patientID,
                    recordId: recordID,
                    originalRelativePath: final.finalRelativePath,
                    derivedRelativePath: final.finalPreviewRelativePath,
                    displayFileName: final.staged.displayName,
                    kind: final.staged.kind,
                    pageIndex: index,
                    uniformTypeIdentifier: final.staged.uniformTypeIdentifier,
                    byteCount: final.staged.byteCount,
                    sha256: final.staged.sha256,
                    importedAt: final.staged.createdAt,
                    importSource: request.source.importSource,
                    pixelWidth: final.staged.pixelWidth,
                    pixelHeight: final.staged.pixelHeight,
                    pageCount: final.staged.pageCount,
                    derivedArtifacts:
                        final.staged.derivedArtifacts ?? .legacyMissing
                )
            }
            let title = aggregate.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let record = MedicalRecord(
                id: recordID,
                patientId: request.patientID,
                type: resolvedType,
                title: title,
                summary: aggregate.summary,
                eventDate: request.eventDate,
                hospital: aggregate.hospital,
                department: aggregate.department,
                sourceType: request.source.sourceType,
                ocrText: aggregateText,
                ocrEngineIdentifier: VisionOCREngine().identifier,
                machineExtractionRevision: 1,
                confirmedRevision: 0,
                confirmedAt: nil,
                machineExtraction: aggregate,
                labItems: aggregate.labItems,
                abnormalFlags: aggregate.abnormalFlags,
                structuredFields: aggregate.structuredFields,
                reviewStatus: .pending,
                attachments: attachments
            )
            let decision: AssignmentDecision = evidence.outcome == .match
                ? .acceptedMatch
                : .acceptedWithoutNameEvidence
            _ = try CaptureCommitService(context: context).commit(
                CaptureCommitRequest(
                    draftId: draft.id,
                    expectedGeneration: draft.generation,
                    expectedOutcome: evidence.outcome,
                    decision: decision,
                    overrideReason: nil,
                    assignedPatientId: request.patientID,
                    record: record,
                    engineIdentifier: VisionOCREngine().identifier,
                    engineVersion: nil
                )
            )
            do {
                try vault.markDatabaseCommitted(finalized)
                try vault.completeBatchIfPossible(assets[0].batchID)
            } catch {
                // Database + immutable originals are already committed. The
                // durable filesMoved journal lets startup reconciliation mark
                // this transaction complete; never move committed originals
                // back into staging.
                AppLog.vault.error(
                    "Committed elder capture awaits startup Vault reconciliation"
                )
            }
            AppLog.userAction.info(
                "Elder capture saved pending family review"
            )
            return ElderCaptureResult(
                record: record,
                ocrWasEmpty: aggregateText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        } catch {
            finalized.reversed().forEach(vault.rollbackFinalization)
            throw error
        }
    }
}
