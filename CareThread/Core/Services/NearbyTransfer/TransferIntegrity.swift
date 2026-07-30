import CryptoKit
import Foundation

struct TransferCommitPlan: Equatable, Sendable {
    let transferID: UUID
    let scope: TransferScope
    let patientIDs: Set<UUID>
    let entityCount: Int
    let fileCount: Int
    let totalByteCount: Int64
}

/// Unforgeable outside this file. The database importer can only be called with
/// a token created after manifest, domain graph and every staged file validate.
struct VerifiedTransfer: Sendable {
    let plan: TransferCommitPlan
    let manifestSHA256: String
    /// Portable-content fingerprints used by the importer for deterministic
    /// UUID conflict handling.
    let entityFingerprints: [UUID: String]
    let validatedEnvelopes: [UUID: ValidatedTransferDomainEnvelopeV1]
    let validatedFiles: [ValidatedTransferFileDescriptor]
    let preview: TransferPreviewCounts
    let capabilities: [TransferCapability]
    fileprivate let manifest: TransferManifest

    fileprivate init(
        plan: TransferCommitPlan,
        manifestSHA256: String,
        entityFingerprints: [UUID: String],
        validatedEnvelopes: [UUID: ValidatedTransferDomainEnvelopeV1],
        validatedFiles: [ValidatedTransferFileDescriptor],
        preview: TransferPreviewCounts,
        capabilities: [TransferCapability],
        manifest: TransferManifest
    ) {
        self.plan = plan
        self.manifestSHA256 = manifestSHA256
        self.entityFingerprints = entityFingerprints
        self.validatedEnvelopes = validatedEnvelopes
        self.validatedFiles = validatedFiles
        self.preview = preview
        self.capabilities = capabilities
        self.manifest = manifest
    }
}

enum TransferIntegrityVerifier {
    static func verifyCommitReadiness(
        sealedManifest: SealedTransferManifest,
        session: NearbyTransferSession,
        stagingStore: TransferStagingStore,
        existingPatientIDs: Set<UUID> = []
    ) async throws -> VerifiedTransfer {
        let manifest = try await session.openIncomingManifest(
            sealedManifest,
            existingPatientIDs: existingPatientIDs
        )
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: manifest.entities.map { ($0.entityID, $0) }
        )
        let filesByID = Dictionary(
            uniqueKeysWithValues: manifest.files.map { ($0.fileID, $0) }
        )

        var resolvedFilePaths: Set<String> = []
        var envelopes: [UUID: ValidatedTransferDomainEnvelopeV1] = [:]
        var validatedFiles: [ValidatedTransferFileDescriptor] = []
        var entityFingerprints: [UUID: String] = [:]
        for descriptor in manifest.files {
            let validated = try descriptor.validated()
            validatedFiles.append(validated)
            let url = try await stagingStore.verifiedFileURL(
                transferID: manifest.transferID,
                descriptor: validated
            )
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == descriptor.byteCount else {
                throw TransferProtocolError.fileSizeMismatch(fileID: descriptor.fileID)
            }
            guard resolvedFilePaths.insert(url.standardizedFileURL.path).inserted else {
                throw TransferProtocolError.invalidManifest("duplicate staging file")
            }
            let digest = try TransferFileHashing.sha256(url: url)
            guard digest == descriptor.sha256 else {
                throw TransferProtocolError.fileHashMismatch(fileID: descriptor.fileID)
            }

            if descriptor.kind == .domainSnapshot {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let envelope = try TransferDomainEnvelopeV1.decodeStrict(from: data)
                guard envelopes[envelope.entityID] == nil else {
                    throw TransferProtocolError.invalidManifest("duplicate domain payload")
                }
                envelopes[envelope.entityID] = envelope
                entityFingerprints[envelope.entityID] = Data(
                    SHA256.hash(data: data)
                ).hexString
            }
        }

        guard envelopes.count == manifest.entities.count else {
            throw TransferProtocolError.invalidManifest("domain payload count mismatch")
        }
        for entity in manifest.entities {
            guard let payloadFile = filesByID[entity.payloadFileID],
                  payloadFile.kind == .domainSnapshot,
                  let envelope = envelopes[entity.entityID],
                  envelope.kind == entity.kind,
                  envelope.entityID == entity.entityID,
                  envelope.patientID == entity.patientID,
                  envelope.revision == entity.revision else {
                throw TransferProtocolError.invalidManifest("descriptor payload mismatch")
            }
            for reference in envelope.references {
                guard let target = descriptorsByID[reference.entityID],
                      target.kind == reference.kind,
                      target.patientID == entity.patientID else {
                    throw TransferProtocolError.invalidManifest("reference closure violation")
                }
            }
            try validateRequiredRelationships(
                envelope,
                descriptorsByID: descriptorsByID,
                filesByID: filesByID
            )
        }
        let claimedPayloadFileIDs = Set(manifest.entities.map(\.payloadFileID))
        let domainFileIDs = Set(
            manifest.files.lazy
                .filter { $0.kind == .domainSnapshot }
                .map(\.fileID)
        )
        guard claimedPayloadFileIDs == domainFileIDs else {
            throw TransferProtocolError.invalidManifest("orphan domain payload")
        }

        let plan = TransferCommitPlan(
            transferID: manifest.transferID,
            scope: manifest.scope,
            patientIDs: Set(manifest.entities.map(\.patientID)),
            entityCount: manifest.entities.count,
            fileCount: manifest.files.count,
            totalByteCount: manifest.totalByteCount
        )
        return VerifiedTransfer(
            plan: plan,
            manifestSHA256: sealedManifest.manifestSHA256,
            entityFingerprints: entityFingerprints,
            validatedEnvelopes: envelopes,
            validatedFiles: validatedFiles,
            preview: manifest.preview,
            capabilities: manifest.capabilities,
            manifest: manifest
        )
    }

    private static func validateRequiredRelationships(
        _ envelope: ValidatedTransferDomainEnvelopeV1,
        descriptorsByID: [UUID: TransferEntityDescriptor],
        filesByID: [UUID: TransferFileDescriptor]
    ) throws {
        let references = Dictionary(
            uniqueKeysWithValues: envelope.references.map { ($0.entityID, $0.kind) }
        )
        func requireReference(_ id: UUID, field: String, kind: TransferEntityKind) throws {
            guard references[id] == kind,
                  descriptorsByID[id]?.patientID == envelope.patientID else {
                throw TransferProtocolError.invalidManifest(
                    "\(envelope.kind.rawValue) missing \(field) reference"
                )
            }
        }

        switch envelope.fields {
        case let .attachment(recordID, originalFileID, _, sha256):
            try requireReference(recordID, field: "recordID", kind: .medicalRecord)
            guard let file = filesByID[originalFileID],
                  file.kind == .originalAttachment,
                  file.patientID == envelope.patientID,
                  file.ownerAttachmentID == envelope.entityID,
                  sha256 == file.sha256 else {
                throw TransferProtocolError.invalidManifest(
                    "attachment original ownership mismatch"
                )
            }
        case let .recordTag(recordID, _):
            try requireReference(recordID, field: "recordID", kind: .medicalRecord)
        case let .contentRevision(targetID, targetKind, _, _):
            do {
                try requireReference(
                    targetID,
                    field: "targetEntityID",
                    kind: targetKind
                )
            } catch {
                throw TransferProtocolError.invalidManifest(
                    "content revision target mismatch"
                )
            }
        case let .labMeasurement(_, _, recordID):
            if let recordID {
                try requireReference(recordID, field: "recordID", kind: .medicalRecord)
            }
        case let .followUp(_, _, medicalOrderID):
            if let medicalOrderID {
                try requireReference(
                    medicalOrderID,
                    field: "medicalOrderID",
                    kind: .medicalOrder
                )
            }
        case let .reminder(_, _, _, medicationID, recordID):
            if let medicationID {
                try requireReference(
                    medicationID,
                    field: "medicationID",
                    kind: .medication
                )
            }
            if let recordID {
                try requireReference(recordID, field: "recordID", kind: .medicalRecord)
            }
        case let .assignmentAudit(_, _, recordID):
            if let recordID {
                try requireReference(recordID, field: "recordID", kind: .medicalRecord)
            }
        case .patient, .medicalRecord, .medication, .medicalOrder:
            break
        }
    }
}

enum TransferUUIDConflictResolution: Equatable, Sendable {
    case insert
    case idempotentExisting
}

/// V1 importer contract: a UUID may be reused only when the stable portable
/// payload hash is identical. A mismatch aborts the whole transaction; it is
/// never overwritten or silently remapped.
enum TransferUUIDConflictPolicyV1 {
    static func preflight(
        incoming: [UUID: String],
        existing: [UUID: String]
    ) throws -> [UUID: TransferUUIDConflictResolution] {
        var result: [UUID: TransferUUIDConflictResolution] = [:]
        for (entityID, incomingHash) in incoming {
            guard isSHA256(incomingHash) else {
                throw TransferProtocolError.invalidManifest("entity fingerprint")
            }
            if let existingHash = existing[entityID] {
                guard existingHash.lowercased() == incomingHash.lowercased() else {
                    throw TransferProtocolError.uuidConflict(entityID)
                }
                result[entityID] = .idempotentExisting
            } else {
                result[entityID] = .insert
            }
        }
        return result
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}

struct TransferCommitReceipt: Codable, Equatable, Sendable {
    let transferID: UUID
    let manifestSHA256: String
    let resultSHA256: String
    let committedAtUTC: String
    let authenticationTag: Data
}

struct VerifiedCommitReceipt: Sendable {
    let transferID: UUID
    let resultSHA256: String

    fileprivate init(transferID: UUID, resultSHA256: String) {
        self.transferID = transferID
        self.resultSHA256 = resultSHA256
    }
}

private struct UnsignedCommitReceipt: Codable {
    let transferID: UUID
    let manifestSHA256: String
    let resultSHA256: String
    let committedAtUTC: String
}

enum TransferCommitCoordinator {
    /// The closure is the future transactional SwiftData importer boundary. A
    /// journal is durably switched to `committing` before it runs, so launch
    /// recovery can distinguish an interrupted commit from receiving.
    static func commitOnReceiver(
        _ verified: VerifiedTransfer,
        stagingStore: TransferStagingStore,
        session: NearbyTransferSession,
        committedAtUTC: String,
        importer: @Sendable (VerifiedTransfer) async throws -> String
    ) async throws -> TransferCommitReceipt {
        guard ISO8601DateFormatter().date(from: committedAtUTC) != nil else {
            throw TransferProtocolError.invalidManifest("commit timestamp")
        }
        if let recovered = await stagingStore.committedReceipt(
            transferID: verified.plan.transferID
        ) {
            guard recovered.manifestSHA256 == verified.manifestSHA256 else {
                throw TransferProtocolError.invalidCommitReceipt
            }
            let unsigned = UnsignedCommitReceipt(
                transferID: recovered.transferID,
                manifestSHA256: recovered.manifestSHA256,
                resultSHA256: recovered.resultSHA256,
                committedAtUTC: recovered.committedAtUTC
            )
            let key = try await session.receiverCommitReceiptKey()
            let refreshed = TransferCommitReceipt(
                transferID: unsigned.transferID,
                manifestSHA256: unsigned.manifestSHA256,
                resultSHA256: unsigned.resultSHA256,
                committedAtUTC: unsigned.committedAtUTC,
                authenticationTag: Data(
                    HMAC<SHA256>.authenticationCode(
                        for: try StableJSON.encode(unsigned),
                        using: key
                    )
                )
            )
            try await stagingStore.refreshCommittedReceipt(
                transferID: verified.plan.transferID,
                receipt: refreshed
            )
            return refreshed
        }
        try await stagingStore.markCommitting(transferID: verified.plan.transferID)
        // Importer contract: transferID is the durable idempotency key. If the
        // process stopped after database commit but before journal receipt
        // persistence, recovery calls the importer again with the same token.
        let resultSHA256 = try await importer(verified).lowercased()
        guard Self.isSHA256(resultSHA256) else {
            throw TransferProtocolError.invalidCommitReceipt
        }

        let unsigned = UnsignedCommitReceipt(
            transferID: verified.plan.transferID,
            manifestSHA256: verified.manifestSHA256,
            resultSHA256: resultSHA256,
            committedAtUTC: committedAtUTC
        )
        let key = try await session.receiverCommitReceiptKey()
        let tag = HMAC<SHA256>.authenticationCode(
            for: try StableJSON.encode(unsigned),
            using: key
        )
        let receipt = TransferCommitReceipt(
            transferID: unsigned.transferID,
            manifestSHA256: unsigned.manifestSHA256,
            resultSHA256: unsigned.resultSHA256,
            committedAtUTC: unsigned.committedAtUTC,
            authenticationTag: Data(tag)
        )
        try await stagingStore.markCommitted(
            transferID: verified.plan.transferID,
            resultSHA256: resultSHA256,
            receipt: receipt
        )
        return receipt
    }

    static func verifyOnSender(
        _ receipt: TransferCommitReceipt,
        expectedTransferID: UUID,
        expectedManifestSHA256: String,
        session: NearbyTransferSession
    ) async throws -> VerifiedCommitReceipt {
        guard receipt.transferID == expectedTransferID,
              receipt.manifestSHA256 == expectedManifestSHA256,
              isSHA256(receipt.manifestSHA256),
              isSHA256(receipt.resultSHA256),
              ISO8601DateFormatter().date(from: receipt.committedAtUTC) != nil else {
            throw TransferProtocolError.invalidCommitReceipt
        }
        let unsigned = UnsignedCommitReceipt(
            transferID: receipt.transferID,
            manifestSHA256: receipt.manifestSHA256,
            resultSHA256: receipt.resultSHA256,
            committedAtUTC: receipt.committedAtUTC
        )
        let key = try await session.senderExpectedCommitReceiptKey()
        guard HMAC<SHA256>.isValidAuthenticationCode(
            receipt.authenticationTag,
            authenticating: try StableJSON.encode(unsigned),
            using: key
        ) else {
            throw TransferProtocolError.invalidCommitReceipt
        }
        return VerifiedCommitReceipt(
            transferID: receipt.transferID,
            resultSHA256: receipt.resultSHA256
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}
