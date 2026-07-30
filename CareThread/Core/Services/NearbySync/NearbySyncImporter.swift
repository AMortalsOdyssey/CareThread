import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

struct NearbySyncReceivePlan: Sendable {
    let transferID: UUID
    let scope: TransferScope
    let preview: TransferPreviewCounts
    let totalByteCount: Int64
    let insertedEntityCount: Int
    let idempotentEntityCount: Int
    let originalFileCount: Int
    let resolutions: [UUID: TransferUUIDConflictResolution]
    let payloads: [UUID: NearbySyncEntityPayloadV1]
}

@MainActor
final class NearbySyncReceiverPreflight {
    private let context: ModelContext
    private let vault: CaptureVaultService
    private let stagingStore: TransferStagingStore
    private let fileManager: FileManager

    init(
        context: ModelContext,
        vault: CaptureVaultService,
        stagingStore: TransferStagingStore,
        fileManager: FileManager = .default
    ) {
        self.context = context
        self.vault = vault
        self.stagingStore = stagingStore
        self.fileManager = fileManager
    }

    func evaluate(_ verified: VerifiedTransfer) async throws -> NearbySyncReceivePlan {
        guard verified.capabilities.contains(NearbySyncContract.capability),
              verified.plan.totalByteCount <= NearbySyncContract.maximumTransferBytes,
              verified.preview.memberCount <= TransferLimits.maximumMembers else {
            throw NearbySyncError.malformedPayload
        }
        let existingPatients = try context.fetch(FetchDescriptor<Patient>())
        let incomingPatientIDs = verified.plan.patientIDs
        guard Set(existingPatients.map(\.id)).union(incomingPatientIDs).count
            <= TransferLimits.maximumMembers else {
            throw NearbySyncError.memberLimit
        }
        try checkStorage(requiredBytes: verified.plan.totalByteCount)

        var payloads: [UUID: NearbySyncEntityPayloadV1] = [:]
        for (entityID, envelope) in verified.validatedEnvelopes {
            guard let data = envelope.portablePayload else {
                throw NearbySyncError.malformedPayload
            }
            payloads[entityID] = try NearbySyncEntityPayloadV1.decode(
                data,
                envelope: envelope
            )
        }
        guard payloads.count == verified.plan.entityCount else {
            throw NearbySyncError.incompleteTransfer
        }

        let exporter = NearbySyncExporter(context: context, vault: vault)
        let existingFingerprints = try exporter.currentFingerprints()
        let resolutions: [UUID: TransferUUIDConflictResolution]
        do {
            resolutions = try TransferUUIDConflictPolicyV1.preflight(
                incoming: verified.entityFingerprints,
                existing: existingFingerprints
            )
        } catch let TransferProtocolError.uuidConflict(id) {
            throw NearbySyncError.conflict(id)
        }
        let inserted = resolutions.values.filter { $0 == .insert }.count
        let originals = verified.validatedFiles.filter {
            $0.kind == .originalAttachment
                && resolutions[$0.ownerAttachmentID ?? UUID()] == .insert
        }.count
        return NearbySyncReceivePlan(
            transferID: verified.plan.transferID,
            scope: verified.plan.scope,
            preview: verified.preview,
            totalByteCount: verified.plan.totalByteCount,
            insertedEntityCount: inserted,
            idempotentEntityCount: resolutions.count - inserted,
            originalFileCount: originals,
            resolutions: resolutions,
            payloads: payloads
        )
    }

    private func checkStorage(requiredBytes: Int64) throws {
        let values = try vault.rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available >= requiredBytes + TransferLimits.minimumFreeSpaceBytes else {
            throw NearbySyncError.storageUnavailable
        }
    }
}

struct NearbySyncImportResult: Equatable, Sendable {
    let transferID: UUID
    let insertedEntityCount: Int
    let idempotentEntityCount: Int
    let resultSHA256: String
}

@MainActor
final class NearbySyncImporter {
    private let context: ModelContext
    private let vault: CaptureVaultService
    private let stagingStore: TransferStagingStore
    private let fileManager: FileManager

    init(
        context: ModelContext,
        vault: CaptureVaultService,
        stagingStore: TransferStagingStore,
        fileManager: FileManager = .default
    ) {
        self.context = context
        self.vault = vault
        self.stagingStore = stagingStore
        self.fileManager = fileManager
    }

    func importVerified(
        _ verified: VerifiedTransfer,
        userConfirmedManifest: Bool,
        cancellation: @Sendable () -> Bool = { false }
    ) async throws -> NearbySyncImportResult {
        guard userConfirmedManifest else {
            throw NearbySyncError.cancelled
        }
        if cancellation() { throw NearbySyncError.cancelled }
        let preflight = NearbySyncReceiverPreflight(
            context: context,
            vault: vault,
            stagingStore: stagingStore,
            fileManager: fileManager
        )
        let plan = try await preflight.evaluate(verified)
        if cancellation() { throw NearbySyncError.cancelled }

        let vaultTransaction = NearbySyncVaultTransaction(
            vaultRoot: vault.rootURL,
            transferID: verified.plan.transferID,
            fileManager: fileManager
        )
        var attachmentPaths: [UUID: String] = [:]
        do {
            for descriptor in verified.validatedFiles
            where descriptor.kind == .originalAttachment {
                guard let attachmentID = descriptor.ownerAttachmentID,
                      let payload = plan.payloads[attachmentID]?.attachment else {
                    throw NearbySyncError.incompleteTransfer
                }
                guard plan.resolutions[attachmentID] == .insert else { continue }
                if cancellation() { throw NearbySyncError.cancelled }
                let source = try await stagingStore.verifiedFileURL(
                    transferID: verified.plan.transferID,
                    descriptor: descriptor
                )
                attachmentPaths[attachmentID] = try vaultTransaction.finalize(
                    stagedURL: source,
                    patientID: descriptor.patientID,
                    attachmentID: attachmentID,
                    recordID: payload.recordID,
                    uniformTypeIdentifier: payload.uniformTypeIdentifier,
                    expectedByteCount: payload.byteCount,
                    expectedSHA256: payload.sha256
                )
            }
            if cancellation() { throw NearbySyncError.cancelled }
            try insert(
                plan: plan,
                attachmentPaths: attachmentPaths,
                cancellation: cancellation
            )
            try context.save()
            vaultTransaction.commit()
        } catch {
            context.rollback()
            vaultTransaction.rollback()
            throw error
        }
        let resultSHA = resultFingerprint(
            verified: verified,
            resolutions: plan.resolutions
        )
        return NearbySyncImportResult(
            transferID: plan.transferID,
            insertedEntityCount: plan.insertedEntityCount,
            idempotentEntityCount: plan.idempotentEntityCount,
            resultSHA256: resultSHA
        )
    }

    func commitImporter(
        userConfirmedManifest: @escaping @Sendable () -> Bool,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) -> @Sendable (VerifiedTransfer) async throws -> String {
        { [self] verified in
            return try await self.importVerified(
                verified,
                userConfirmedManifest: userConfirmedManifest(),
                cancellation: cancellation
            ).resultSHA256
        }
    }

    func insert(
        plan: NearbySyncReceivePlan,
        attachmentPaths: [UUID: String],
        cancellation: @Sendable () -> Bool
    ) throws {
        let inserts = plan.payloads.filter {
            plan.resolutions[$0.key] == .insert
        }
        var records = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<MedicalRecord>())
                .map { ($0.id, $0) }
        )

        for payload in ordered(inserts, kind: .patient) {
            guard let body = payload.patient else { throw NearbySyncError.payloadMismatch }
            let value = Patient(
                id: payload.entityID,
                displayName: body.editable.displayName,
                reportName: body.editable.reportName,
                aliases: body.editable.aliases,
                birthDate: body.editable.birthDate,
                gender: body.editable.gender,
                conditions: body.editable.conditions,
                allergies: body.editable.allergies,
                histories: body.editable.histories,
                careQuestions: body.editable.careQuestions,
                createdAt: body.createdAt,
                updatedAt: body.editable.updatedAt
            )
            value.restoreContentRevision(body.contentRevision)
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .medicalRecord) {
            guard let body = payload.medicalRecord else {
                throw NearbySyncError.payloadMismatch
            }
            let editable = body.editable
            let value = MedicalRecord(
                id: payload.entityID,
                patientId: payload.patientID,
                type: editable.type,
                title: editable.title,
                summary: editable.summary,
                eventDate: editable.eventDate,
                eventDatePrecision: editable.eventDatePrecision,
                eventTimezoneIdentifier: editable.eventTimezoneIdentifier,
                hospital: editable.hospital,
                department: editable.department,
                doctor: editable.doctor,
                primaryDisease: editable.primaryDisease,
                ageAtEvent: editable.ageAtEvent,
                sourceType: body.sourceType,
                ocrText: body.ocrText,
                ocrEngineIdentifier: body.ocrEngineIdentifier,
                ocrEngineVersion: body.ocrEngineVersion,
                extractionSchemaVersion: body.extractionSchemaVersion,
                machineExtractionRevision: body.machineExtractionRevision,
                confirmedRevision: editable.confirmedRevision,
                confirmedAt: editable.confirmedAt,
                machineExtraction: body.machineExtraction,
                abnormalFlags: editable.abnormalFlags,
                structuredFields: editable.structuredFields,
                reviewStatus: editable.reviewStatus,
                isKeyRecord: editable.isKeyRecord,
                inBrief: editable.inBrief,
                createdAt: body.createdAt,
                updatedAt: editable.updatedAt
            )
            value.restoreContentRevision(body.contentRevision)
            context.insert(value)
            records[value.id] = value
        }
        for payload in ordered(inserts, kind: .medication) {
            guard let body = payload.medication else { throw NearbySyncError.payloadMismatch }
            let editable = body.editable
            let value = Medication(
                id: payload.entityID,
                patientId: payload.patientID,
                name: editable.name,
                doseValue: editable.doseValue,
                doseUnit: editable.doseUnit,
                frequency: editable.frequency,
                weeklyCount: editable.weeklyCount,
                usageNotes: editable.usageNotes,
                startDate: editable.startDate,
                endDate: editable.endDate,
                isLongTerm: editable.isLongTerm,
                hospital: editable.hospital,
                department: editable.department,
                linkedDiagnosis: editable.linkedDiagnosis,
                caution: editable.caution,
                sourceRecordId: body.sourceRecordID,
                previousVersionId: body.previousVersionID,
                reminderEnabled: editable.reminderEnabled,
                reminderTimes: editable.reminderTimes,
                remainingQuantity: editable.remainingQuantity,
                refillReminderAt: editable.refillReminderAt,
                lifecycleStatus: editable.lifecycleStatus,
                createdAt: body.createdAt,
                updatedAt: editable.updatedAt,
                contentRevision: body.contentRevision
            )
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .medicalOrder) {
            guard let body = payload.medicalOrder else {
                throw NearbySyncError.payloadMismatch
            }
            let value = MedicalOrder(
                id: payload.entityID,
                patientId: payload.patientID,
                content: body.editable.content,
                sourceRecordId: body.sourceRecordID,
                generatedFollowUpId: body.generatedFollowUpID,
                isCompleted: body.editable.isCompleted,
                createdAt: body.createdAt,
                updatedAt: body.editable.updatedAt,
                contentRevision: body.contentRevision
            )
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .followUp) {
            guard let body = payload.followUp else { throw NearbySyncError.payloadMismatch }
            let editable = body.editable
            let value = FollowUp(
                id: payload.entityID,
                patientId: payload.patientID,
                sourceOrderId: body.sourceOrderID,
                plannedDate: editable.plannedDate,
                items: editable.items,
                reason: editable.reason,
                bringRecordIds: editable.bringRecordIds,
                compareRecordId: editable.compareRecordId,
                status: editable.status,
                completedAt: editable.completedAt,
                resultRecordId: editable.resultRecordId,
                reminderEnabled: editable.reminderEnabled,
                createdAt: body.createdAt,
                updatedAt: editable.updatedAt,
                contentRevision: body.contentRevision
            )
            context.insert(value)
        }
        if cancellation() { throw NearbySyncError.cancelled }

        for payload in ordered(inserts, kind: .attachment) {
            guard let body = payload.attachment,
                  let path = attachmentPaths[payload.entityID],
                  let record = records[body.recordID] else {
                throw NearbySyncError.incompleteTransfer
            }
            let value = try Attachment.verified(
                id: payload.entityID,
                patientId: payload.patientID,
                recordId: body.recordID,
                originalRelativePath: path,
                displayFileName: body.displayFileName,
                kind: body.kind,
                pageIndex: body.pageIndex,
                uniformTypeIdentifier: body.uniformTypeIdentifier,
                byteCount: body.byteCount,
                sha256: body.sha256,
                importedAt: body.importedAt,
                importSource: body.importSource,
                pixelWidth: body.pixelWidth,
                pixelHeight: body.pixelHeight,
                pageCount: body.pageCount
            )
            try record.bindAttachment(value)
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .labMeasurement) {
            guard let body = payload.labMeasurement,
                  let record = records[body.recordID] else {
                throw NearbySyncError.incompleteTransfer
            }
            let editable = body.editable
            let value = LabMeasurement(
                id: payload.entityID,
                patientId: payload.patientID,
                recordId: body.recordID,
                displayName: editable.displayName,
                numericValue: editable.numericValue,
                textualValue: editable.textualValue,
                unit: editable.unit,
                referenceLow: editable.referenceLow,
                referenceHigh: editable.referenceHigh,
                referenceText: editable.referenceText,
                abnormalState: editable.abnormalState,
                confidence: editable.confidence,
                eventDate: editable.eventDate
            )
            value.restoreContentRevision(body.contentRevision)
            try value.bind(to: record)
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .recordTag) {
            guard let body = payload.recordTag,
                  let record = records[body.recordID] else {
                throw NearbySyncError.incompleteTransfer
            }
            let value = RecordTag(
                id: payload.entityID,
                patientId: payload.patientID,
                recordId: body.recordID,
                kind: body.editable.kind,
                displayValue: body.editable.displayValue
            )
            value.restoreContentRevision(body.contentRevision)
            try value.bind(to: record)
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .reminder) {
            guard let body = payload.reminder else { throw NearbySyncError.payloadMismatch }
            let editable = body.editable
            let value = try ReminderSchedule(
                id: payload.entityID,
                patientId: payload.patientID,
                kind: editable.kind,
                title: editable.title,
                notes: editable.notes,
                schedule: editable.schedule,
                revision: editable.businessRevision,
                isEnabled: editable.isEnabled,
                sourceRecordId: body.sourceRecordID,
                sourceMedicationId: body.sourceMedicationID,
                sourceFollowUpId: body.sourceFollowUpID,
                createdAt: body.createdAt,
                updatedAt: editable.updatedAt
            )
            value.restoreContentRevision(body.contentRevision)
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .assignmentAudit) {
            guard let body = payload.assignmentAudit else {
                throw NearbySyncError.payloadMismatch
            }
            let value = RecordAssignmentAudit(
                id: payload.entityID,
                capturedForPatientId: body.capturedForPatientID,
                assignedPatientId: body.assignedPatientID,
                draftId: body.draftID,
                recordId: body.recordID,
                detectedName: body.detectedName,
                outcome: body.outcome,
                decision: body.decision,
                overrideReason: body.overrideReason,
                engineIdentifier: body.engineIdentifier,
                engineVersion: body.engineVersion,
                createdAt: body.createdAt
            )
            context.insert(value)
        }
        for payload in ordered(inserts, kind: .contentRevision) {
            guard let body = payload.contentRevision else {
                throw NearbySyncError.payloadMismatch
            }
            let value = ContentRevision(
                id: payload.entityID,
                entityKind: body.entityKind,
                entityId: body.targetEntityID,
                patientId: payload.patientID,
                revision: body.revision,
                changedFieldKeys: body.changedFieldKeys,
                beforeContentPayload: body.beforeContentPayload,
                afterContentPayload: body.afterContentPayload,
                source: body.source,
                actor: body.actor,
                createdAt: body.createdAt
            )
            context.insert(value)
        }

        // Relationship binding deliberately enforces graph integrity and may update
        // aggregate timestamps. Restore the sender's revisioned record content only
        // after every child is bound so a committed graph keeps the exact canonical
        // fingerprint and a lost receipt can be replayed idempotently.
        for payload in ordered(inserts, kind: .medicalRecord) {
            guard let body = payload.medicalRecord,
                  let record = records[payload.entityID] else {
                throw NearbySyncError.incompleteTransfer
            }
            record.applyEditableContent(body.editable)
            record.restoreContentRevision(body.contentRevision)
        }
    }

    private func ordered(
        _ values: [UUID: NearbySyncEntityPayloadV1],
        kind: TransferEntityKind
    ) -> [NearbySyncEntityPayloadV1] {
        values.values.filter { $0.kind == kind }.sorted {
            $0.entityID.uuidString < $1.entityID.uuidString
        }
    }

    private func resultFingerprint(
        verified: VerifiedTransfer,
        resolutions: [UUID: TransferUUIDConflictResolution]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(verified.manifestSHA256.utf8))
        for id in resolutions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.update(data: Data(id.uuidString.lowercased().utf8))
            hasher.update(data: Data((verified.entityFingerprints[id] ?? "").utf8))
        }
        return Data(hasher.finalize()).hexString
    }
}

private final class NearbySyncVaultTransaction {
    private let root: URL
    private let transferID: UUID
    private let fileManager: FileManager
    private var finalizedURLs: [URL] = []
    private var committed = false

    init(vaultRoot: URL, transferID: UUID, fileManager: FileManager) {
        root = vaultRoot.standardizedFileURL
        self.transferID = transferID
        self.fileManager = fileManager
    }

    func finalize(
        stagedURL: URL,
        patientID: UUID,
        attachmentID: UUID,
        recordID: UUID,
        uniformTypeIdentifier: String,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) throws -> String {
        let ext = safeExtension(
            typeIdentifier: uniformTypeIdentifier,
            fallbackURL: stagedURL
        )
        let relative = "members/\(patientID.uuidString)/records/\(recordID.uuidString)"
            + "/attachments/\(attachmentID.uuidString)/original.\(ext)"
        let destination = try resolve(relative)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NearbySyncError.conflict(attachmentID)
        }
        let values = try stagedURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == expectedByteCount,
              try TransferFileHashing.sha256(url: stagedURL)
                == expectedSHA256.lowercased() else {
            throw NearbySyncError.originalChanged(attachmentID)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try fileManager.copyItem(at: stagedURL, to: destination)
        do {
            guard try TransferFileHashing.sha256(url: destination)
                == expectedSHA256.lowercased() else {
                throw NearbySyncError.originalChanged(attachmentID)
            }
            // Extended attributes cannot be changed after the source is locked
            // immutable. Apply and verify backup exclusion first, then freeze it.
            try excludeFromBackup(destination)
            try fileManager.setAttributes(
                [
                    .protectionKey: FileProtectionType.complete,
                    .immutable: true
                ],
                ofItemAtPath: destination.path
            )
            finalizedURLs.append(destination)
            return relative
        } catch {
            try? fileManager.setAttributes(
                [.immutable: false],
                ofItemAtPath: destination.path
            )
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func commit() {
        committed = true
        finalizedURLs.removeAll()
    }

    func rollback() {
        for url in finalizedURLs.reversed() {
            try? fileManager.setAttributes(
                [.immutable: false],
                ofItemAtPath: url.path
            )
            try? fileManager.removeItem(at: url)
        }
        finalizedURLs.removeAll()
    }

    deinit {
        if !committed { rollback() }
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains(".."),
              !relativePath.contains("\\") else {
            throw CaptureVaultError.invalidRelativePath
        }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw CaptureVaultError.invalidRelativePath
        }
        return url
    }

    private func safeExtension(
        typeIdentifier: String,
        fallbackURL: URL
    ) -> String {
        let preferred = UTType(typeIdentifier)?.preferredFilenameExtension?.lowercased()
        let fallback = fallbackURL.pathExtension.lowercased()
        for value in [preferred, fallback].compactMap({ $0 })
        where ["jpg", "jpeg", "png", "heic", "pdf"].contains(value) {
            return value
        }
        return "bin"
    }

    private func excludeFromBackup(_ source: URL) throws {
        var url = source
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        guard try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true else {
            throw CaptureVaultError.backupExclusionFailed
        }
    }
}
