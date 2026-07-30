import CryptoKit
import Foundation
import SwiftData
import ZIPFoundation

enum BackupRestoreFailurePoint {
    case none
    case afterVaultSwap
    case afterDatabaseSave
    /// Test-only process-interruption model. Unlike injected failures above,
    /// these deliberately leave the protected journal and swapped files for a
    /// newly constructed importer to reconcile.
    case simulateInterruptionAfterVaultSwap
    case simulateInterruptionAfterDatabaseSave

    var leavesRecoveryJournal: Bool {
        switch self {
        case .simulateInterruptionAfterVaultSwap,
             .simulateInterruptionAfterDatabaseSave:
            true
        case .none, .afterVaultSwap, .afterDatabaseSave:
            false
        }
    }
}

private struct PreparedBackupRestore: Sendable {
    let transactionRoot: URL
    let newMembersURL: URL
    let oldMembersURL: URL
    let snapshotPayloadURL: URL
    let activeJournalURL: URL
    let membersURL: URL
    let attachmentPaths: [UUID: String]
    let journal: BackupRecoveryJournal
}

private struct BackupRollbackSnapshot: Sendable {
    let payload: BackupPortablePayloadV1
    let attachmentPaths: [UUID: String]
    let transactionRoot: URL
    let activeJournalURL: URL
}

/// Sendable boundary for file-system-only restore work. It deliberately owns
/// no SwiftData context or model objects.
private struct BackupImporterFileWorker: Sendable {
    let vaultRoot: URL
    let temporaryRoot: URL
    let recoveryRoot: URL
    var fileManager: FileManager { .default }

    func preflight(
        archiveURL: URL,
        password: String?
    ) throws -> BackupImportPlan {
        try BackupImporter.preflightSynchronously(
            archiveURL: archiveURL,
            password: password,
            worker: self
        )
    }

    func prepareRestoreFiles(
        plan: BackupImportPlan,
        currentPayload: BackupPortablePayloadV1
    ) throws -> PreparedBackupRestore {
        try BackupImporter.prepareRestoreFiles(
            plan: plan,
            currentPayload: currentPayload,
            worker: self
        )
    }

    func swapVaultForRestore(
        _ prepared: PreparedBackupRestore
    ) throws -> BackupRecoveryJournal {
        try BackupImporter.swapVaultForRestore(prepared, worker: self)
    }

    func prepareInterruptedRecovery() throws -> BackupRollbackSnapshot? {
        try BackupImporter.prepareInterruptedRecovery(worker: self)
    }

    func rollbackFilesAndLoadSnapshot(
        snapshotPayloadURL: URL,
        oldMembersURL: URL,
        currentMembersURL: URL
    ) throws -> BackupRollbackSnapshot {
        try BackupImporter.rollbackFilesAndLoadSnapshot(
            snapshotPayloadURL: snapshotPayloadURL,
            oldMembersURL: oldMembersURL,
            currentMembersURL: currentMembersURL,
            worker: self
        )
    }

    func commit(
        journal: BackupRecoveryJournal,
        prepared: PreparedBackupRestore,
        plan: BackupImportPlan
    ) throws {
        var committed = journal
        committed.state = .databaseCommitted
        try BackupImporter.writeJournal(
            committed,
            to: prepared.activeJournalURL,
            worker: self
        )
        try BackupImporter.retainSuccessfulSnapshot(
            payloadURL: prepared.snapshotPayloadURL,
            oldMembersURL: prepared.oldMembersURL,
            worker: self
        )
        try? fileManager.removeItem(at: prepared.transactionRoot)
        try? fileManager.removeItem(at: prepared.activeJournalURL)
        plan.discard(fileManager: fileManager)
    }

    func cleanup(_ snapshot: BackupRollbackSnapshot) {
        try? fileManager.removeItem(at: snapshot.transactionRoot)
        try? fileManager.removeItem(at: snapshot.activeJournalURL)
    }

    func cleanup(_ prepared: PreparedBackupRestore) {
        try? fileManager.removeItem(at: prepared.transactionRoot)
        try? fileManager.removeItem(at: prepared.activeJournalURL)
    }
}

final class BackupImporter {
    private let context: ModelContext
    private let vault: CaptureVaultService
    private let fileManager: FileManager
    private let temporaryRoot: URL
    private let recoveryRoot: URL
    private let failurePoint: BackupRestoreFailurePoint
    private let fileWorker: BackupImporterFileWorker

    init(
        context: ModelContext,
        vault: CaptureVaultService,
        temporaryRoot: URL? = nil,
        recoveryRoot: URL? = nil,
        fileManager: FileManager = .default,
        failurePoint: BackupRestoreFailurePoint = .none
    ) {
        self.context = context
        self.vault = vault
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "CareThreadRestore",
                isDirectory: true
            )
        self.recoveryRoot = recoveryRoot
            ?? vault.rootURL.appendingPathComponent(".snapshot", isDirectory: true)
        self.failurePoint = failurePoint
        self.fileWorker = BackupImporterFileWorker(
            vaultRoot: vault.rootURL,
            temporaryRoot: self.temporaryRoot,
            recoveryRoot: self.recoveryRoot
        )
    }

    func preflight(
        archiveURL: URL,
        password: String? = nil
    ) throws -> BackupImportPlan {
        try fileWorker.preflight(archiveURL: archiveURL, password: password)
    }

    /// Production preflight path. Decryption, ZIP scanning/extraction, hash
    /// verification and JSON decoding all execute away from MainActor.
    func preflight(
        archiveURL: URL,
        password: String? = nil
    ) async throws -> BackupImportPlan {
        let worker = fileWorker
        return try await runBackupWorker {
            try Task.checkCancellation()
            return try worker.preflight(
                archiveURL: archiveURL,
                password: password
            )
        }
    }

    fileprivate nonisolated static func preflightSynchronously(
        archiveURL: URL,
        password: String?,
        worker: BackupImporterFileWorker
    ) throws -> BackupImportPlan {
        let staging = worker.temporaryRoot.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try createProtectedDirectory(staging, worker: worker)
        do {
            let archiveForScan: URL
            if BackupEncryption.isEncryptedBackup(archiveURL) {
                guard let password, !password.isEmpty else {
                    throw BackupError.passwordRequired
                }
                let decrypted = staging.appendingPathComponent("decrypted.zip")
                try BackupEncryption.decrypt(
                    encryptedURL: archiveURL,
                    password: password,
                    outputZipURL: decrypted
                )
                archiveForScan = decrypted
            } else {
                archiveForScan = archiveURL
            }
            try Task.checkCancellation()
            try scanArchive(archiveForScan, worker: worker)
            let extraction = staging.appendingPathComponent(
                "content",
                isDirectory: true
            )
            try createProtectedDirectory(extraction, worker: worker)
            try worker.fileManager.unzipItem(at: archiveForScan, to: extraction)
            try Task.checkCancellation()
            try validateExtractedTree(extraction, worker: worker)
            let root = try locateContentRoot(extraction, worker: worker)
            let manifestURL = root.appendingPathComponent("manifest.json")
            let manifestData = try boundedData(
                manifestURL,
                maximum: 4 * 1_024 * 1_024,
                worker: worker
            )
            let manifest: BackupManifest
            do {
                manifest = try StableJSON.decode(
                    BackupManifest.self,
                    from: manifestData
                )
            } catch {
                throw BackupError.invalidManifest
            }
            try manifest.validate()
            try validateManifestFiles(manifest, root: root, worker: worker)
            let payloadURL = root.appendingPathComponent("portable/domain.json")
            let payloadData = try boundedData(
                payloadURL,
                maximum: BackupLimits.maximumPortableJSONBytes,
                worker: worker
            )
            let payload: BackupPortablePayloadV1
            do {
                payload = try StableJSON.decode(
                    BackupPortablePayloadV1.self,
                    from: payloadData
                )
            } catch {
                throw BackupError.unsupportedSchema
            }
            guard payload.schemaVersion == 1 else {
                throw BackupError.unsupportedSchema
            }
            try validate(
                payload: payload,
                manifest: manifest,
                root: root,
                worker: worker
            )
            let total = manifest.files.reduce(Int64(0)) { $0 + $1.byteCount }
            try ensureStorage(bytes: total, worker: worker)
            let preview = BackupPreview(
                backupID: manifest.backupID,
                exportedAt: manifest.exportedAt,
                memberNames: manifest.memberNames,
                memberCount: manifest.entityCounts["patients"] ?? 0,
                recordCount: manifest.entityCounts["medicalRecords"] ?? 0,
                attachmentCount: manifest.entityCounts["attachments"] ?? 0,
                totalByteCount: total
            )
            AppLog.data.info("Backup preflight completed")
            return BackupImportPlan(
                manifest: manifest,
                preview: preview,
                stagingContainerURL: staging,
                stagedRootURL: root,
                portablePayload: payload
            )
        } catch {
            try? worker.fileManager.removeItem(at: staging)
            AppLog.data.error("Backup preflight failed")
            throw error
        }
    }

    @MainActor
    func restore(
        plan: BackupImportPlan,
        userConfirmed: Bool
    ) throws -> BackupImportResult {
        guard userConfirmed else { throw BackupError.restoreNotConfirmed }
        let transactionID = UUID()
        let transactionRoot = vault.rootURL
            .appendingPathComponent(".restore", isDirectory: true)
            .appendingPathComponent(transactionID.uuidString.lowercased(), isDirectory: true)
        let newMembers = transactionRoot.appendingPathComponent(
            "new-members",
            isDirectory: true
        )
        let oldMembers = transactionRoot.appendingPathComponent(
            "old-members",
            isDirectory: true
        )
        let snapshotPayloadURL = transactionRoot.appendingPathComponent(
            "snapshot.json"
        )
        let activeJournalURL = recoveryRoot.appendingPathComponent("active.json")
        let membersURL = vault.rootURL.appendingPathComponent(
            "members",
            isDirectory: true
        )

        try Self.createProtectedDirectory(transactionRoot, worker: fileWorker)
        do {
            let currentPayload = try BackupExporter(
                context: context,
                vault: vault,
                temporaryRoot: temporaryRoot,
                fileManager: fileManager
            ).collectPayload(scope: .allMembers)
            try StableJSON.encode(currentPayload).write(
                to: snapshotPayloadURL,
                options: [.atomic, .completeFileProtection]
            )
            try Self.harden(snapshotPayloadURL, worker: fileWorker)
            let attachmentPaths = try Self.stageOriginals(
                plan: plan,
                newMembersRoot: newMembers,
                worker: fileWorker
            )
            try Self.createProtectedDirectory(
                recoveryRoot,
                worker: fileWorker
            )
            var journal = BackupRecoveryJournal(
                transactionID: transactionID,
                snapshotPayloadRelativePath: Self.relativeToVault(
                    snapshotPayloadURL,
                    worker: fileWorker
                ),
                oldMembersRelativePath: Self.relativeToVault(
                    oldMembers,
                    worker: fileWorker
                ),
                state: .prepared
            )
            try Self.writeJournal(
                journal,
                to: activeJournalURL,
                worker: fileWorker
            )

            if fileManager.fileExists(atPath: membersURL.path) {
                try fileManager.moveItem(at: membersURL, to: oldMembers)
            } else {
                try Self.createProtectedDirectory(
                    oldMembers,
                    worker: fileWorker
                )
            }
            try fileManager.moveItem(at: newMembers, to: membersURL)
            journal.state = .vaultSwapped
            try Self.writeJournal(
                journal,
                to: activeJournalURL,
                worker: fileWorker
            )
            if failurePoint == .afterVaultSwap {
                throw BackupError.injectedFailure
            }

            do {
                try replaceDatabase(
                    with: plan.portablePayload,
                    attachmentPaths: attachmentPaths
                )
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            if failurePoint == .afterDatabaseSave {
                throw BackupError.injectedFailure
            }
            journal.state = .databaseCommitted
            try Self.writeJournal(
                journal,
                to: activeJournalURL,
                worker: fileWorker
            )
            try Self.retainSuccessfulSnapshot(
                payloadURL: snapshotPayloadURL,
                oldMembersURL: oldMembers,
                worker: fileWorker
            )
            try? fileManager.removeItem(at: transactionRoot)
            try? fileManager.removeItem(at: activeJournalURL)
            plan.discard(fileManager: fileManager)
            AppLog.data.info("Backup restore completed")
            return BackupImportResult(
                backupID: plan.manifest.backupID,
                memberCount: plan.preview.memberCount,
                recordCount: plan.preview.recordCount,
                attachmentCount: plan.preview.attachmentCount
            )
        } catch {
            AppLog.data.error("Backup restore failed; rolling back")
            do {
                try rollback(
                    snapshotPayloadURL: snapshotPayloadURL,
                    oldMembersURL: oldMembers,
                    currentMembersURL: membersURL
                )
                try? fileManager.removeItem(at: transactionRoot)
                try? fileManager.removeItem(at: activeJournalURL)
            } catch {
                AppLog.data.error("Backup restore rollback failed")
                throw BackupError.recoveryFailed
            }
            throw error
        }
    }

    /// Production restore path. MainActor owns only the SwiftData snapshot and
    /// replacement transaction. Original copying, protected snapshot encoding,
    /// journal I/O, vault directory moves and cleanup execute on a detached
    /// worker.
    @MainActor
    func restore(
        plan: BackupImportPlan,
        userConfirmed: Bool
    ) async throws -> BackupImportResult {
        guard userConfirmed else { throw BackupError.restoreNotConfirmed }
        let currentPayload = try BackupExporter(
            context: context,
            vault: vault,
            temporaryRoot: temporaryRoot,
            fileManager: fileManager
        ).collectPayload(scope: .allMembers)
        let worker = fileWorker

        let prepared = try await runBackupWorker {
            try Task.checkCancellation()
            return try worker.prepareRestoreFiles(
                plan: plan,
                currentPayload: currentPayload
            )
        }

        do {
            let swapped = try await runBackupWorker {
                try Task.checkCancellation()
                return try worker.swapVaultForRestore(prepared)
            }
            if failurePoint == .afterVaultSwap
                || failurePoint == .simulateInterruptionAfterVaultSwap {
                throw BackupError.injectedFailure
            }

            do {
                try Task.checkCancellation()
                try replaceDatabase(
                    with: plan.portablePayload,
                    attachmentPaths: prepared.attachmentPaths
                )
                try context.save()
                try Task.checkCancellation()
            } catch {
                context.rollback()
                throw error
            }
            if failurePoint == .afterDatabaseSave
                || failurePoint == .simulateInterruptionAfterDatabaseSave {
                throw BackupError.injectedFailure
            }

            try await runBackupWorker(priority: .utility) {
                try worker.commit(
                    journal: swapped,
                    prepared: prepared,
                    plan: plan
                )
            }
            AppLog.data.info("Backup restore completed")
            return BackupImportResult(
                backupID: plan.manifest.backupID,
                memberCount: plan.preview.memberCount,
                recordCount: plan.preview.recordCount,
                attachmentCount: plan.preview.attachmentCount
            )
        } catch {
            if failurePoint.leavesRecoveryJournal {
                AppLog.data.warning(
                    "Backup restore interruption simulated; journal retained for reopen recovery"
                )
                throw error
            }
            AppLog.data.error("Backup restore failed; rolling back")
            do {
                // Rollback is deliberately shielded from caller cancellation:
                // once a vault swap may have happened, cleanup must finish.
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try worker.rollbackFilesAndLoadSnapshot(
                        snapshotPayloadURL: prepared.snapshotPayloadURL,
                        oldMembersURL: prepared.oldMembersURL,
                        currentMembersURL: prepared.membersURL
                    )
                }.value
                try replaceDatabase(
                    with: snapshot.payload,
                    attachmentPaths: snapshot.attachmentPaths
                )
                try context.save()
                await Task.detached(priority: .utility) {
                    worker.cleanup(prepared)
                }.value
            } catch {
                context.rollback()
                AppLog.data.error("Backup restore rollback failed")
                throw BackupError.recoveryFailed
            }
            throw error
        }
    }

    /// Called during app bootstrap before health information is shown.
    @MainActor
    func recoverInterruptedRestoreIfNeeded() throws {
        let journalURL = recoveryRoot.appendingPathComponent("active.json")
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        let journal = try StableJSON.decode(
            BackupRecoveryJournal.self,
            from: Self.boundedData(
                journalURL,
                maximum: 64 * 1_024,
                worker: fileWorker
            )
        )
        let snapshot = try Self.resolveVaultRelative(
            journal.snapshotPayloadRelativePath,
            worker: fileWorker
        )
        let oldMembers = try Self.resolveVaultRelative(
            journal.oldMembersRelativePath,
            worker: fileWorker
        )
        let members = vault.rootURL.appendingPathComponent("members", isDirectory: true)
        if journal.state == .databaseCommitted {
            try Self.retainSuccessfulSnapshot(
                payloadURL: snapshot,
                oldMembersURL: oldMembers,
                worker: fileWorker
            )
        } else {
            try rollback(
                snapshotPayloadURL: snapshot,
                oldMembersURL: oldMembers,
                currentMembersURL: members
            )
        }
        let transactionRoot = snapshot.deletingLastPathComponent()
        try? fileManager.removeItem(at: transactionRoot)
        try? fileManager.removeItem(at: journalURL)
        AppLog.data.info("Interrupted backup restore reconciled")
    }

    /// Async startup gate used by the app. It models recovery from persisted
    /// journal state; it is not a claim that simctl force-termination ran.
    @MainActor
    func recoverInterruptedRestoreIfNeeded() async throws {
        let worker = fileWorker
        let snapshot = try await runBackupWorker {
            try worker.prepareInterruptedRecovery()
        }
        if let snapshot {
            do {
                try replaceDatabase(
                    with: snapshot.payload,
                    attachmentPaths: snapshot.attachmentPaths
                )
                try context.save()
                // Database recovery is committed; journal removal must not be
                // interrupted or the next launch could replay stale state.
                await Task.detached(priority: .utility) {
                    worker.cleanup(snapshot)
                }.value
            } catch {
                context.rollback()
                throw BackupError.recoveryFailed
            }
        }
        AppLog.data.info("Interrupted backup restore reconciled")
    }

    fileprivate nonisolated static func prepareRestoreFiles(
        plan: BackupImportPlan,
        currentPayload: BackupPortablePayloadV1,
        worker: BackupImporterFileWorker
    ) throws -> PreparedBackupRestore {
        try Task.checkCancellation()
        let transactionID = UUID()
        let transactionRoot = worker.vaultRoot
            .appendingPathComponent(".restore", isDirectory: true)
            .appendingPathComponent(
                transactionID.uuidString.lowercased(),
                isDirectory: true
            )
        let newMembers = transactionRoot.appendingPathComponent(
            "new-members",
            isDirectory: true
        )
        let oldMembers = transactionRoot.appendingPathComponent(
            "old-members",
            isDirectory: true
        )
        let snapshotPayloadURL = transactionRoot.appendingPathComponent(
            "snapshot.json"
        )
        let activeJournalURL = worker.recoveryRoot.appendingPathComponent("active.json")
        let membersURL = worker.vaultRoot.appendingPathComponent(
            "members",
            isDirectory: true
        )

        try createProtectedDirectory(transactionRoot, worker: worker)
        do {
            let snapshotData = try StableJSON.encode(currentPayload)
            try BackupLimits.validatePortableJSONByteCount(
                Int64(snapshotData.count)
            )
            try snapshotData.write(
                to: snapshotPayloadURL,
                options: [.atomic, .completeFileProtection]
            )
            try harden(snapshotPayloadURL, worker: worker)
            try Task.checkCancellation()
            let attachmentPaths = try stageOriginals(
                plan: plan,
                newMembersRoot: newMembers,
                worker: worker
            )
            try createProtectedDirectory(worker.recoveryRoot, worker: worker)
            let journal = BackupRecoveryJournal(
                transactionID: transactionID,
                snapshotPayloadRelativePath: relativeToVault(
                    snapshotPayloadURL,
                    worker: worker
                ),
                oldMembersRelativePath: relativeToVault(
                    oldMembers,
                    worker: worker
                ),
                state: .prepared
            )
            try writeJournal(journal, to: activeJournalURL, worker: worker)
            return PreparedBackupRestore(
                transactionRoot: transactionRoot,
                newMembersURL: newMembers,
                oldMembersURL: oldMembers,
                snapshotPayloadURL: snapshotPayloadURL,
                activeJournalURL: activeJournalURL,
                membersURL: membersURL,
                attachmentPaths: attachmentPaths,
                journal: journal
            )
        } catch {
            try? worker.fileManager.removeItem(at: transactionRoot)
            throw error
        }
    }

    fileprivate nonisolated static func swapVaultForRestore(
        _ prepared: PreparedBackupRestore,
        worker: BackupImporterFileWorker
    ) throws -> BackupRecoveryJournal {
        try Task.checkCancellation()
        if worker.fileManager.fileExists(atPath: prepared.membersURL.path) {
            try worker.fileManager.moveItem(
                at: prepared.membersURL,
                to: prepared.oldMembersURL
            )
        } else {
            try createProtectedDirectory(
                prepared.oldMembersURL,
                worker: worker
            )
        }
        do {
            try worker.fileManager.moveItem(
                at: prepared.newMembersURL,
                to: prepared.membersURL
            )
            var journal = prepared.journal
            journal.state = .vaultSwapped
            try writeJournal(
                journal,
                to: prepared.activeJournalURL,
                worker: worker
            )
            return journal
        } catch {
            if worker.fileManager.fileExists(atPath: prepared.oldMembersURL.path),
               !worker.fileManager.fileExists(atPath: prepared.membersURL.path) {
                try? worker.fileManager.moveItem(
                    at: prepared.oldMembersURL,
                    to: prepared.membersURL
                )
            }
            throw error
        }
    }

    fileprivate nonisolated static func prepareInterruptedRecovery(
        worker: BackupImporterFileWorker
    ) throws -> BackupRollbackSnapshot? {
        let journalURL = worker.recoveryRoot.appendingPathComponent("active.json")
        guard worker.fileManager.fileExists(atPath: journalURL.path) else {
            return nil
        }
        let journal = try StableJSON.decode(
            BackupRecoveryJournal.self,
            from: boundedData(
                journalURL,
                maximum: 64 * 1_024,
                worker: worker
            )
        )
        let snapshot = try resolveVaultRelative(
            journal.snapshotPayloadRelativePath,
            worker: worker
        )
        let oldMembers = try resolveVaultRelative(
            journal.oldMembersRelativePath,
            worker: worker
        )
        let members = worker.vaultRoot.appendingPathComponent(
            "members",
            isDirectory: true
        )
        if journal.state == .databaseCommitted {
            try retainSuccessfulSnapshot(
                payloadURL: snapshot,
                oldMembersURL: oldMembers,
                worker: worker
            )
            try? worker.fileManager.removeItem(
                at: snapshot.deletingLastPathComponent()
            )
            try? worker.fileManager.removeItem(at: journalURL)
            return nil
        }
        return try rollbackFilesAndLoadSnapshot(
            snapshotPayloadURL: snapshot,
            oldMembersURL: oldMembers,
            currentMembersURL: members,
            worker: worker
        )
    }

    fileprivate nonisolated static func rollbackFilesAndLoadSnapshot(
        snapshotPayloadURL: URL,
        oldMembersURL: URL,
        currentMembersURL: URL,
        worker: BackupImporterFileWorker
    ) throws -> BackupRollbackSnapshot {
        let hasOldMembers = worker.fileManager.fileExists(
            atPath: oldMembersURL.path
        )
        // A `.prepared` journal can exist before any vault swap, and a prior
        // recovery attempt may already have restored old-members. In both
        // cases the absence of old-members means current members are the
        // authoritative files and must not be moved aside.
        if hasOldMembers,
           worker.fileManager.fileExists(atPath: currentMembersURL.path) {
            let failed = currentMembersURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".failed-import-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
            try worker.fileManager.moveItem(at: currentMembersURL, to: failed)
            try? unlockAndRemove(failed, worker: worker)
        }
        if hasOldMembers {
            try worker.fileManager.moveItem(
                at: oldMembersURL,
                to: currentMembersURL
            )
        }
        let data = try boundedData(
            snapshotPayloadURL,
            maximum: BackupLimits.maximumPortableJSONBytes,
            worker: worker
        )
        let payload = try StableJSON.decode(
            BackupPortablePayloadV1.self,
            from: data
        )
        var paths: [UUID: String] = [:]
        for entity in payload.entities {
            try Task.checkCancellation()
            guard let body = entity.attachment else { continue }
            let prefix = "members/\(entity.patientID.uuidString)"
                + "/records/\(body.recordID.uuidString)"
                + "/attachments/\(entity.entityID.uuidString)"
            let directory = worker.vaultRoot.appendingPathComponent(prefix)
            let children = try worker.fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            guard let child = children.first(where: {
                $0.lastPathComponent.hasPrefix("original.")
            }) else {
                throw BackupError.missingOriginal
            }
            paths[entity.entityID] = "\(prefix)/\(child.lastPathComponent)"
        }
        return BackupRollbackSnapshot(
            payload: payload,
            attachmentPaths: paths,
            transactionRoot: snapshotPayloadURL.deletingLastPathComponent(),
            activeJournalURL: worker.recoveryRoot.appendingPathComponent(
                "active.json"
            )
        )
    }

    private nonisolated static func scanArchive(
        _ archiveURL: URL,
        worker: BackupImporterFileWorker
    ) throws {
        let values = try archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupError.unsupportedArchive
        }
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw BackupError.unsupportedArchive
        }
        var seen: Set<String> = []
        var count = 0
        var expanded: Int64 = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= BackupLimits.maximumEntries else {
                throw BackupError.tooManyEntries
            }
            let normalizedPath = entry.path.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            guard BackupPathPolicy.isSafeRelativePath(normalizedPath) else {
                throw BackupError.unsafePath
            }
            let collisionKey = normalizedPath
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard seen.insert(collisionKey).inserted else {
                throw BackupError.duplicateEntry
            }
            guard entry.type == .file || entry.type == .directory else {
                throw BackupError.symbolicLink
            }
            let uncompressed = Int64(entry.uncompressedSize)
            let compressed = Int64(entry.compressedSize)
            guard uncompressed <= BackupLimits.maximumEntryBytes else {
                throw BackupError.archiveTooLarge
            }
            expanded = min(Int64.max, expanded + uncompressed)
            guard expanded <= BackupLimits.maximumExpandedBytes else {
                throw BackupError.archiveTooLarge
            }
            if uncompressed > 1_024 * 1_024,
               compressed > 0,
               uncompressed / compressed > BackupLimits.maximumCompressionRatio {
                throw BackupError.suspiciousCompression
            }
        }
        guard count > 0 else { throw BackupError.unsupportedArchive }
    }

    private nonisolated static func validateExtractedTree(
        _ root: URL,
        worker: BackupImporterFileWorker
    ) throws {
        guard let enumerator = worker.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw BackupError.unsupportedArchive
        }
        var count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= BackupLimits.maximumEntries else {
                throw BackupError.tooManyEntries
            }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw BackupError.symbolicLink
            }
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw BackupError.unsafePath
            }
            try harden(url, worker: worker)
        }
    }

    private nonisolated static func locateContentRoot(
        _ staging: URL,
        worker: BackupImporterFileWorker
    ) throws -> URL {
        let direct = staging.appendingPathComponent("manifest.json")
        if worker.fileManager.fileExists(atPath: direct.path) { return staging }
        let children = try worker.fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        guard children.count == 1,
              worker.fileManager.fileExists(
                  atPath: children[0].appendingPathComponent("manifest.json").path
              ) else {
            throw BackupError.invalidManifest
        }
        return children[0]
    }

    private nonisolated static func validateManifestFiles(
        _ manifest: BackupManifest,
        root: URL,
        worker: BackupImporterFileWorker
    ) throws {
        let declared = Set(manifest.files.map(\.relativePath))
        var actual: Set<String> = []
        guard let enumerator = worker.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw BackupError.invalidManifest
        }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(
                url.standardizedFileURL.path.dropFirst(
                    root.standardizedFileURL.path.count + 1
                )
            )
            if relative != "manifest.json" { actual.insert(relative) }
        }
        guard actual == declared else {
            throw BackupError.manifestCountMismatch
        }
        for file in manifest.files {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(file.relativePath)
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == file.byteCount,
                  try BackupExporter.sha256(url) == file.sha256 else {
                throw BackupError.integrityMismatch
            }
        }
    }

    private nonisolated static func validate(
        payload: BackupPortablePayloadV1,
        manifest: BackupManifest,
        root: URL,
        worker: BackupImporterFileWorker
    ) throws {
        let grouped = Dictionary(grouping: payload.entities, by: \.kind)
        let counts: [String: Int] = [
            "patients": grouped[.patient]?.count ?? 0,
            "medicalRecords": grouped[.medicalRecord]?.count ?? 0,
            "attachments": grouped[.attachment]?.count ?? 0,
            "medications": grouped[.medication]?.count ?? 0,
            "medicalOrders": grouped[.medicalOrder]?.count ?? 0,
            "followUps": grouped[.followUp]?.count ?? 0,
            "labMeasurements": grouped[.labMeasurement]?.count ?? 0,
            "reminders": grouped[.reminder]?.count ?? 0,
            "assignmentAudits": grouped[.assignmentAudit]?.count ?? 0,
            "recordTags": grouped[.recordTag]?.count ?? 0,
            "importBatches": payload.importBatches.count,
            "captureDrafts": payload.captureDrafts.count,
            "capturePages": payload.capturePages.count,
            "appleReminderBindings": payload.appleReminderBindings.count,
            "contentRevisions": payload.contentRevisions.count
        ]
        guard counts == manifest.entityCounts else {
            throw BackupError.manifestCountMismatch
        }
        let patients = grouped[.patient] ?? []
        guard !patients.isEmpty,
              patients.count <= BackupLimits.maximumMembers,
              manifest.memberNames.count == patients.count else {
            throw BackupError.memberLimit
        }
        let patientIDs = Set(patients.map { $0.patientID })
        let entityIDs = Set(payload.entities.map(\.entityID))
        guard entityIDs.count == payload.entities.count else {
            throw BackupError.invalidRelationship
        }
        for entity in payload.entities {
            guard patientIDs.contains(entity.patientID) else {
                throw BackupError.invalidRelationship
            }
            try entity.validate(
                kind: entity.kind,
                entityID: entity.entityID,
                patientID: entity.patientID
            )
        }
        let targetsByID = Dictionary(
            uniqueKeysWithValues: payload.entities.map {
                (
                    $0.entityID,
                    NearbySyncRelationshipTarget(
                        kind: $0.kind,
                        patientID: $0.patientID
                    )
                )
            }
        )
        for entity in payload.entities {
            do {
                try NearbySyncEntityRelationshipPolicy.validateTargetClosure(
                    payload: entity,
                    targetsByID: targetsByID
                )
            } catch {
                throw BackupError.invalidRelationship
            }
        }
        let attachments = grouped[.attachment] ?? []
        for attachment in attachments {
            guard try originalURL(
                      attachmentID: attachment.entityID,
                      patientID: attachment.patientID,
                      root: root,
                      worker: worker
                  ) != nil else {
                throw BackupError.invalidRelationship
            }
        }
        guard Set(payload.importBatches.map(\.id)).count
                == payload.importBatches.count,
              Set(payload.captureDrafts.map(\.id)).count
                == payload.captureDrafts.count,
              Set(payload.capturePages.map(\.id)).count
                == payload.capturePages.count,
              Set(payload.appleReminderBindings.map(\.id)).count
                == payload.appleReminderBindings.count,
              Set(payload.contentRevisions.map(\.id)).count
                == payload.contentRevisions.count else {
            throw BackupError.invalidRelationship
        }
        let batchOwnerByID = Dictionary(
            uniqueKeysWithValues: payload.importBatches.map {
                ($0.id, $0.patientID)
            }
        )
        let draftByID = Dictionary(
            uniqueKeysWithValues: payload.captureDrafts.map {
                ($0.id, $0)
            }
        )
        let pageByID = Dictionary(
            uniqueKeysWithValues: payload.capturePages.map {
                ($0.id, $0)
            }
        )
        guard payload.importBatches.allSatisfy({ batch in
                  patientIDs.contains(batch.patientID)
              }),
              payload.captureDrafts.allSatisfy({ draft in
                  patientIDs.contains(draft.patientID)
                      && batchOwnerByID[draft.batchID] == draft.patientID
              }),
              payload.capturePages.allSatisfy({ page in
                  patientIDs.contains(page.patientID)
                      && batchOwnerByID[page.batchID] == page.patientID
                      && draftByID[page.draftID]?.patientID == page.patientID
                      && draftByID[page.draftID]?.batchID == page.batchID
                      && (
                          page.attachmentID.map { attachmentID in
                              targetsByID[attachmentID]?.kind == .attachment
                                  && targetsByID[attachmentID]?.patientID
                                      == page.patientID
                          } ?? true
                      )
              }),
              payload.appleReminderBindings.allSatisfy({ binding in
                  patientIDs.contains(binding.patientID)
                      && targetsByID[binding.reminderID]?.kind == .reminder
                      && targetsByID[binding.reminderID]?.patientID
                          == binding.patientID
              }),
              payload.contentRevisions.allSatisfy({ revision in
                  patientIDs.contains(revision.patientID)
                      && revisionTargetOwner(
                          for: revision,
                          entityTargets: targetsByID,
                          draftsByID: draftByID,
                          pagesByID: pageByID
                      ) == revision.patientID
              }) else {
            throw BackupError.invalidRelationship
        }
    }

    private nonisolated static func revisionTargetOwner(
        for revision: BackupContentRevisionDTO,
        entityTargets: [UUID: NearbySyncRelationshipTarget],
        draftsByID: [UUID: BackupCaptureDraftDTO],
        pagesByID: [UUID: BackupCapturePageDTO]
    ) -> UUID? {
        switch revision.entityKind {
        case .captureDraft:
            return draftsByID[revision.entityID]?.patientID
        case .capturePage:
            return pagesByID[revision.entityID]?.patientID
        default:
            guard let expectedKind = NearbySyncSnapshotFactory.transferKind(
                for: revision.entityKind
            ), let target = entityTargets[revision.entityID],
                  target.kind == expectedKind else {
                return nil
            }
            return target.patientID
        }
    }

    private nonisolated static func stageOriginals(
        plan: BackupImportPlan,
        newMembersRoot: URL,
        worker: BackupImporterFileWorker
    ) throws -> [UUID: String] {
        try createProtectedDirectory(newMembersRoot, worker: worker)
        var paths: [UUID: String] = [:]
        let attachments = plan.portablePayload.entities.filter {
            $0.kind == .attachment
        }
        for entity in attachments {
            try Task.checkCancellation()
            guard let body = entity.attachment,
                  let source = try originalURL(
                      attachmentID: entity.entityID,
                      patientID: entity.patientID,
                      root: plan.stagedRootURL,
                      worker: worker
                  ) else {
                throw BackupError.missingOriginal
            }
            let ext = source.pathExtension.isEmpty
                ? "bin"
                : source.pathExtension.lowercased()
            let relative = "members/\(entity.patientID.uuidString)"
                + "/records/\(body.recordID.uuidString)"
                + "/attachments/\(entity.entityID.uuidString)/original.\(ext)"
            let withinMembers = String(relative.dropFirst("members/".count))
            let destination = newMembersRoot.appendingPathComponent(withinMembers)
            try worker.fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try worker.fileManager.copyItem(at: source, to: destination)
            guard try BackupExporter.sha256(destination) == body.sha256,
                  Int64(
                      try destination.resourceValues(forKeys: [.fileSizeKey])
                          .fileSize ?? -1
                  ) == body.byteCount else {
                throw BackupError.integrityMismatch
            }
            try harden(destination, worker: worker)
            try worker.fileManager.setAttributes(
                [.immutable: true],
                ofItemAtPath: destination.path
            )
            paths[entity.entityID] = relative
        }
        return paths
    }

    @MainActor
    private func replaceDatabase(
        with payload: BackupPortablePayloadV1,
        attachmentPaths: [UUID: String]
    ) throws {
        try deleteAllKnownModels()
        let byID = Dictionary(
            uniqueKeysWithValues: payload.entities.map { ($0.entityID, $0) }
        )
        let resolutions = Dictionary(
            uniqueKeysWithValues: payload.entities.map {
                ($0.entityID, TransferUUIDConflictResolution.insert)
            }
        )
        let transferRoot = temporaryRoot.appendingPathComponent(
            "domain-inserter",
            isDirectory: true
        )
        let stagingStore = try TransferStagingStore(
            rootURL: transferRoot,
            minimumFreeSpaceBytes: 0
        )
        let importer = NearbySyncImporter(
            context: context,
            vault: vault,
            stagingStore: stagingStore,
            fileManager: fileManager
        )
        let patientCount = payload.entities.filter { $0.kind == .patient }.count
        let recordCount = payload.entities.filter { $0.kind == .medicalRecord }.count
        let attachmentCount = payload.entities.filter { $0.kind == .attachment }.count
        let plan = NearbySyncReceivePlan(
            transferID: UUID(),
            scope: .allPatients,
            preview: TransferPreviewCounts(
                memberCount: patientCount,
                recordCount: recordCount,
                attachmentCount: attachmentCount
            ),
            totalByteCount: 0,
            insertedEntityCount: payload.entities.count,
            idempotentEntityCount: 0,
            originalFileCount: attachmentCount,
            resolutions: resolutions,
            payloads: byID
        )
        try importer.insert(
            plan: plan,
            attachmentPaths: attachmentPaths,
            cancellation: { false }
        )
        try insertAdditional(payload)
    }

    private func insertAdditional(_ payload: BackupPortablePayloadV1) throws {
        var batches: [UUID: ImportBatch] = [:]
        for dto in payload.importBatches {
            let value = ImportBatch(
                id: dto.id,
                patientId: dto.patientID,
                sourceType: dto.sourceType,
                status: dto.stateStatus,
                generation: dto.generation,
                createdAt: dto.createdAt
            )
            value.restoreState(
                ImportBatchState(
                    status: dto.stateStatus,
                    generation: dto.generation,
                    updatedAt: dto.updatedAt
                )
            )
            context.insert(value)
            batches[value.id] = value
        }
        var drafts: [UUID: CaptureDraft] = [:]
        for dto in payload.captureDrafts {
            guard let batch = batches[dto.batchID] else {
                throw BackupError.invalidRelationship
            }
            let value = CaptureDraft(
                id: dto.id,
                patientId: dto.patientID,
                batchId: dto.batchID,
                documentIndex: dto.documentIndex,
                groupingRevision: dto.groupingRevision,
                generation: dto.generation,
                titleSuggestion: dto.titleSuggestion,
                confirmedTitle: dto.confirmedTitle,
                sourceType: dto.sourceType,
                attachmentPaths: dto.attachmentPaths,
                selectedType: dto.selectedType,
                selectedDate: dto.selectedDate,
                ocrText: dto.ocrText,
                machineExtraction: dto.machineExtraction,
                updatedAt: dto.updatedAt,
                batch: batch
            )
            value.restoreContentRevision(dto.contentRevision)
            context.insert(value)
            drafts[value.id] = value
        }
        for dto in payload.capturePages {
            guard let draft = drafts[dto.draftID] else {
                throw BackupError.invalidRelationship
            }
            let value = CapturePage(
                id: dto.id,
                patientId: dto.patientID,
                batchId: dto.batchID,
                draftId: dto.draftID,
                sourceOrder: dto.sourceOrder,
                pageIndex: dto.pageIndex,
                stagingRelativePath: dto.stagingRelativePath,
                attachmentId: dto.attachmentID,
                ocrGeneration: dto.ocrGeneration,
                ocrStatus: dto.ocrStatus,
                ocrText: dto.ocrText,
                detectedNameCandidates: dto.detectedNameCandidates,
                hospitalSuggestion: dto.hospitalSuggestion,
                dateSuggestion: dto.dateSuggestion,
                titleSuggestion: dto.titleSuggestion,
                pageMarker: dto.pageMarker,
                overlapFingerprint: dto.overlapFingerprint,
                confirmedHospital: dto.confirmedHospital,
                confirmedDate: dto.confirmedDate,
                confirmedTitle: dto.confirmedTitle,
                createdAt: dto.createdAt,
                draft: draft
            )
            value.restoreContentRevision(dto.contentRevision)
            context.insert(value)
        }
        for dto in payload.appleReminderBindings {
            let value = AppleReminderBinding(
                id: dto.id,
                patientId: dto.patientID,
                reminderId: dto.reminderID,
                destination: dto.destination,
                localNotificationIdentifier: dto.localNotificationIdentifier,
                calendarEventIdentifier: dto.calendarEventIdentifier,
                createdAt: dto.createdAt
            )
            value.updateIdentifiers(
                localNotificationIdentifier: dto.localNotificationIdentifier,
                calendarEventIdentifier: dto.calendarEventIdentifier,
                at: dto.updatedAt
            )
            context.insert(value)
        }
        for dto in payload.contentRevisions {
            context.insert(
                ContentRevision(
                    id: dto.id,
                    entityKind: dto.entityKind,
                    entityId: dto.entityID,
                    patientId: dto.patientID,
                    revision: dto.revision,
                    changedFieldKeys: dto.changedFieldKeys,
                    beforeContentPayload: dto.beforeContentPayload,
                    afterContentPayload: dto.afterContentPayload,
                    source: dto.source,
                    actor: dto.actor,
                    createdAt: dto.createdAt
                )
            )
        }
    }

    private func deleteAllKnownModels() throws {
        try delete(ContentRevision.self)
        try delete(AppleReminderBinding.self)
        try delete(ReminderSchedule.self)
        try delete(RecordAssignmentAudit.self)
        try delete(CapturePage.self)
        try delete(CaptureDraft.self)
        try delete(ImportBatch.self)
        try delete(RecordTag.self)
        try delete(LabMeasurement.self)
        try delete(Attachment.self)
        try delete(FollowUp.self)
        try delete(MedicalOrder.self)
        try delete(Medication.self)
        try delete(MedicalRecord.self)
        try delete(Patient.self)
    }

    private func delete<T: PersistentModel>(_ type: T.Type) throws {
        for value in try context.fetch(FetchDescriptor<T>()) {
            context.delete(value)
        }
    }

    @MainActor
    private func rollback(
        snapshotPayloadURL: URL,
        oldMembersURL: URL,
        currentMembersURL: URL
    ) throws {
        let hasOldMembers = fileManager.fileExists(atPath: oldMembersURL.path)
        if hasOldMembers,
           fileManager.fileExists(atPath: currentMembersURL.path) {
            let failed = currentMembersURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".failed-import-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
            try fileManager.moveItem(at: currentMembersURL, to: failed)
            try? Self.unlockAndRemove(failed, worker: fileWorker)
        }
        if hasOldMembers {
            try fileManager.moveItem(at: oldMembersURL, to: currentMembersURL)
        }
        if fileManager.fileExists(atPath: snapshotPayloadURL.path) {
            let data = try Self.boundedData(
                snapshotPayloadURL,
                maximum: BackupLimits.maximumPortableJSONBytes,
                worker: fileWorker
            )
            let payload = try StableJSON.decode(
                BackupPortablePayloadV1.self,
                from: data
            )
            var paths: [UUID: String] = [:]
            for entity in payload.entities {
                guard let body = entity.attachment else { continue }
                let prefix = "members/\(entity.patientID.uuidString)"
                    + "/records/\(body.recordID.uuidString)"
                    + "/attachments/\(entity.entityID.uuidString)"
                let dir = vault.rootURL.appendingPathComponent(prefix)
                let children = try fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                )
                guard let child = children.first(where: {
                    $0.lastPathComponent.hasPrefix("original.")
                }) else {
                    throw BackupError.missingOriginal
                }
                paths[entity.entityID] = "\(prefix)/\(child.lastPathComponent)"
            }
            try replaceDatabase(with: payload, attachmentPaths: paths)
            try context.save()
        }
    }

    fileprivate nonisolated static func retainSuccessfulSnapshot(
        payloadURL: URL,
        oldMembersURL: URL,
        worker: BackupImporterFileWorker
    ) throws {
        let latest = worker.recoveryRoot.appendingPathComponent(
            "latest",
            isDirectory: true
        )
        if worker.fileManager.fileExists(atPath: latest.path) {
            try unlockAndRemove(latest, worker: worker)
        }
        try createProtectedDirectory(latest, worker: worker)
        if worker.fileManager.fileExists(atPath: payloadURL.path) {
            try worker.fileManager.moveItem(
                at: payloadURL,
                to: latest.appendingPathComponent("database.json")
            )
        }
        if worker.fileManager.fileExists(atPath: oldMembersURL.path) {
            try worker.fileManager.moveItem(
                at: oldMembersURL,
                to: latest.appendingPathComponent("vault-members", isDirectory: true)
            )
        }
        try harden(latest, worker: worker)
    }

    private nonisolated static func originalURL(
        attachmentID: UUID,
        patientID: UUID,
        root: URL,
        worker: BackupImporterFileWorker
    ) throws -> URL? {
        let directory = root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(patientID.uuidString.lowercased(), isDirectory: true)
        guard worker.fileManager.fileExists(atPath: directory.path) else {
            return nil
        }
        let prefix = attachmentID.uuidString.lowercased() + "."
        let matches = try worker.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { $0.lastPathComponent.lowercased().hasPrefix(prefix) }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private nonisolated static func ensureStorage(
        bytes: Int64,
        worker: BackupImporterFileWorker
    ) throws {
        let values = try worker.vaultRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < bytes * 2 + BackupLimits.minimumFreeSpaceBytes {
            throw BackupError.insufficientStorage
        }
    }

    private nonisolated static func boundedData(
        _ url: URL,
        maximum: Int64,
        worker: BackupImporterFileWorker
    ) throws -> Data {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              Int64(size) <= maximum else {
            throw BackupError.archiveTooLarge
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private nonisolated static func createProtectedDirectory(
        _ url: URL,
        worker: BackupImporterFileWorker
    ) throws {
        try worker.fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try harden(url, worker: worker)
    }

    private nonisolated static func harden(
        _ url: URL,
        worker: BackupImporterFileWorker
    ) throws {
        try worker.fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private nonisolated static func unlockAndRemove(
        _ root: URL,
        worker: BackupImporterFileWorker
    ) throws {
        if let enumerator = worker.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) {
            for case let url as URL in enumerator {
                try? worker.fileManager.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: url.path
                )
            }
        }
        try? worker.fileManager.setAttributes(
            [.immutable: false],
            ofItemAtPath: root.path
        )
        try worker.fileManager.removeItem(at: root)
    }

    fileprivate nonisolated static func writeJournal(
        _ journal: BackupRecoveryJournal,
        to url: URL,
        worker: BackupImporterFileWorker
    ) throws {
        try StableJSON.encode(journal).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        try harden(url, worker: worker)
    }

    private nonisolated static func relativeToVault(
        _ url: URL,
        worker: BackupImporterFileWorker
    ) -> String {
        String(
            url.standardizedFileURL.path.dropFirst(
                worker.vaultRoot.standardizedFileURL.path.count + 1
            )
        )
    }

    private nonisolated static func resolveVaultRelative(
        _ relative: String,
        worker: BackupImporterFileWorker
    ) throws -> URL {
        guard BackupPathPolicy.isSafeRelativePath(relative) else {
            throw BackupError.recoveryFailed
        }
        let resolved = worker.vaultRoot
            .appendingPathComponent(relative)
            .standardizedFileURL
        guard resolved.path.hasPrefix(
            worker.vaultRoot.standardizedFileURL.path + "/"
        ) else {
            throw BackupError.recoveryFailed
        }
        return resolved
    }

}
