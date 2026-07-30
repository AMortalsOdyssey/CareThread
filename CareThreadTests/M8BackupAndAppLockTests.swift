import CryptoKit
import Foundation
import SwiftData
import Testing
import ZIPFoundation
@testable import CareThread

@Suite(.serialized)
struct M8BackupTests {
    @MainActor
    @Test func exportContainsManifestPortableJSONReadableRecordAndOriginal() throws {
        let fixture = try M8BackupFixture.make()
        try fixture.seedComplete(memberCount: 1, withOriginal: true)
        let package = try fixture.exporter.export(scope: .allMembers)
        let extracted = try fixture.extract(package.archiveURL)

        #expect(FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("manifest.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("portable/domain.json").path
        ))
        let recordFiles = try FileManager.default.contentsOfDirectory(
            at: extracted.appendingPathComponent("records"),
            includingPropertiesForKeys: nil
        )
        #expect(recordFiles.contains { $0.pathExtension == "json" })
        #expect(recordFiles.contains { $0.pathExtension == "md" })
        #expect(package.preview.attachmentCount == 1)
    }

    @MainActor
    @Test func singleMemberExportIsTenantIsolated() throws {
        let fixture = try M8BackupFixture.make()
        let patients = try fixture.seedComplete(memberCount: 2, withOriginal: false)
        let package = try fixture.exporter.export(
            scope: .singleMember(patients[0].id)
        )
        let plan = try fixture.importer.preflight(
            archiveURL: package.archiveURL
        )
        #expect(plan.preview.memberCount == 1)
        #expect(plan.preview.memberNames == [patients[0].displayName])
        #expect(plan.portablePayload.entities.allSatisfy {
            $0.patientID == patients[0].id
        })
    }

    @MainActor
    @Test func allMemberExportIncludesEveryMember() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 3, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        #expect(package.preview.memberCount == 3)
        #expect(package.preview.recordCount == 3)
    }

    @MainActor
    @Test func crossMemberAuditBelongsToAssignedMemberWithoutLeakingCapturedProfile() throws {
        let fixture = try M8BackupFixture.make()
        let patients = try fixture.seedComplete(memberCount: 2, withOriginal: false)
        let records = try fixture.context.fetch(FetchDescriptor<MedicalRecord>())
        let assignedRecord = try #require(
            records.first { $0.patientId == patients[1].id }
        )
        let auditID = UUID()
        fixture.context.insert(
            RecordAssignmentAudit(
                id: auditID,
                capturedForPatientId: patients[0].id,
                assignedPatientId: patients[1].id,
                recordId: assignedRecord.id,
                detectedName: "虚构姓名",
                outcome: .mismatch,
                decision: .switchedMember,
                engineIdentifier: "test.offline"
            )
        )
        try fixture.context.save()

        let assignedPackage = try fixture.exporter.export(
            scope: .singleMember(patients[1].id)
        )
        let assignedPlan = try fixture.importer.preflight(
            archiveURL: assignedPackage.archiveURL
        )
        let exportedPatients = assignedPlan.portablePayload.entities.filter {
            $0.kind == .patient
        }
        let exportedAudit = try #require(
            assignedPlan.portablePayload.entities.first { $0.entityID == auditID }
        )
        #expect(exportedPatients.map(\.entityID) == [patients[1].id])
        #expect(exportedAudit.patientID == patients[1].id)
        #expect(exportedAudit.assignmentAudit?.capturedForPatientID == patients[0].id)
        #expect(!assignedPlan.portablePayload.entities.contains {
            $0.entityID == patients[0].id
        })
        assignedPlan.discard()
        assignedPackage.discard()

        let capturedPackage = try fixture.exporter.export(
            scope: .singleMember(patients[0].id)
        )
        let capturedPlan = try fixture.importer.preflight(
            archiveURL: capturedPackage.archiveURL
        )
        #expect(!capturedPlan.portablePayload.entities.contains {
            $0.entityID == auditID
        })
        capturedPlan.discard()
        capturedPackage.discard()

        let allPackage = try fixture.exporter.export(scope: .allMembers)
        let allPlan = try fixture.importer.preflight(
            archiveURL: allPackage.archiveURL
        )
        #expect(allPlan.portablePayload.entities.contains { $0.entityID == auditID })
        allPlan.discard()
        allPackage.discard()
    }

    @MainActor
    @Test func backupPreflightRejectsAssignmentAuditOwnerTamper() throws {
        let fixture = try M8BackupFixture.make()
        let patients = try fixture.seedComplete(memberCount: 2, withOriginal: false)
        let records = try fixture.context.fetch(FetchDescriptor<MedicalRecord>())
        let assignedRecord = try #require(
            records.first { $0.patientId == patients[1].id }
        )
        let auditID = UUID()
        fixture.context.insert(
            RecordAssignmentAudit(
                id: auditID,
                capturedForPatientId: patients[0].id,
                assignedPatientId: patients[1].id,
                recordId: assignedRecord.id,
                detectedName: "虚构姓名",
                outcome: .mismatch,
                decision: .switchedMember,
                engineIdentifier: "test.offline"
            )
        )
        try fixture.context.save()
        let package = try fixture.exporter.export(scope: .allMembers)
        let valid = try fixture.exporter.collectPayload(scope: .allMembers)
        let entities = valid.entities.map { entity in
            guard entity.entityID == auditID,
                  let body = entity.assignmentAudit else {
                return entity
            }
            return NearbySyncEntityPayloadV1(
                kind: .assignmentAudit,
                entityID: entity.entityID,
                patientID: entity.patientID,
                assignmentAudit: .init(
                    capturedForPatientID: body.capturedForPatientID,
                    assignedPatientID: patients[0].id,
                    draftID: body.draftID,
                    recordID: body.recordID,
                    detectedName: body.detectedName,
                    outcome: body.outcome,
                    decision: body.decision,
                    overrideReason: body.overrideReason,
                    engineIdentifier: body.engineIdentifier,
                    engineVersion: body.engineVersion,
                    createdAt: body.createdAt
                )
            )
        }
        let tampered = BackupPortablePayloadV1(
            schemaVersion: valid.schemaVersion,
            entities: entities,
            importBatches: valid.importBatches,
            captureDrafts: valid.captureDrafts,
            capturePages: valid.capturePages,
            appleReminderBindings: valid.appleReminderBindings,
            contentRevisions: valid.contentRevisions
        )
        let archive = try fixture.archive(
            replacingPortablePayload: tampered,
            in: package
        )

        #expect(throws: BackupError.invalidRelationship) {
            try fixture.importer.preflight(archiveURL: archive)
        }
        package.discard()
    }

    @MainActor
    @Test func backupPreflightRejectsReminderBindingOwnerTamper() throws {
        let fixture = try M8BackupFixture.make()
        let patients = try fixture.seedComplete(
            memberCount: 2,
            withOriginal: false
        )
        let package = try fixture.exporter.export(scope: .allMembers)
        let valid = try fixture.exporter.collectPayload(scope: .allMembers)
        let original = try #require(valid.appleReminderBindings.first)
        let wrongOwner = try #require(
            patients.first { $0.id != original.patientID }
        )
        let tamperedBinding = BackupAppleReminderBindingDTO(
            id: original.id,
            patientID: wrongOwner.id,
            reminderID: original.reminderID,
            destination: original.destination,
            localNotificationIdentifier:
                original.localNotificationIdentifier,
            calendarEventIdentifier: original.calendarEventIdentifier,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        let tampered = BackupPortablePayloadV1(
            schemaVersion: valid.schemaVersion,
            entities: valid.entities,
            importBatches: valid.importBatches,
            captureDrafts: valid.captureDrafts,
            capturePages: valid.capturePages,
            appleReminderBindings: [
                tamperedBinding
            ] + Array(valid.appleReminderBindings.dropFirst()),
            contentRevisions: valid.contentRevisions
        )
        let archive = try fixture.archive(
            replacingPortablePayload: tampered,
            in: package
        )

        #expect(throws: BackupError.invalidRelationship) {
            try fixture.importer.preflight(archiveURL: archive)
        }
        package.discard()
    }

    @MainActor
    @Test func encryptedBackupRoundTripUsesPasswordBeforeArchiveValidation() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.exportEncrypted(
            scope: .allMembers,
            password: "Correct-Horse-2026!"
        )
        #expect(package.archiveURL.pathExtension == BackupEncryption.fileExtension)
        #expect(BackupEncryption.isEncryptedBackup(package.archiveURL))
        let plan = try fixture.importer.preflight(
            archiveURL: package.archiveURL,
            password: "Correct-Horse-2026!"
        )
        #expect(plan.preview.recordCount == 1)
    }

    @MainActor
    @Test func wrongPasswordDoesNotTouchDatabase() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.exportEncrypted(
            scope: .allMembers,
            password: "Correct-Horse-2026!"
        )
        #expect(throws: BackupError.decryptionFailed) {
            try fixture.importer.preflight(
                archiveURL: package.archiveURL,
                password: "Definitely-Wrong!"
            )
        }
        #expect(
            try fixture.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 1
        )
    }

    @MainActor
    @Test func encryptedBackupTamperIsAuthenticated() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.exportEncrypted(
            scope: .allMembers,
            password: "Correct-Horse-2026!"
        )
        var data = try Data(contentsOf: package.archiveURL)
        data[data.count - 1] ^= 0x01
        let tampered = fixture.root.appendingPathComponent("tampered.ctbackup")
        try data.write(to: tampered)
        #expect(throws: BackupError.decryptionFailed) {
            try fixture.importer.preflight(
                archiveURL: tampered,
                password: "Correct-Horse-2026!"
            )
        }
    }

    @MainActor
    @Test func roundTripRestoresCountsAndSpecialCharacters() throws {
        let fixture = try M8BackupFixture.make()
        let seeded = try fixture.seedComplete(
            memberCount: 1,
            withOriginal: true,
            recordTitle: "复诊🙂（A/B）"
        )
        let expectedQuestion = try #require(
            seeded.first?.careQuestions.first
        )
        let package = try fixture.exporter.export(scope: .allMembers)
        let plan = try fixture.importer.preflight(
            archiveURL: package.archiveURL
        )
        let result = try fixture.importer.restore(
            plan: plan,
            userConfirmed: true
        )
        let records = try fixture.context.fetch(FetchDescriptor<MedicalRecord>())
        let patients = try fixture.context.fetch(FetchDescriptor<Patient>())
        #expect(result.recordCount == 1)
        #expect(records.count == 1)
        #expect(records[0].title == "复诊🙂（A/B）")
        let restoredQuestion = try #require(
            patients.first?.careQuestions.first
        )
        #expect(restoredQuestion.id == expectedQuestion.id)
        #expect(restoredQuestion.text == expectedQuestion.text)
        #expect(restoredQuestion.status == expectedQuestion.status)
        #expect(restoredQuestion.answer == expectedQuestion.answer)
        #expect(restoredQuestion.note == expectedQuestion.note)
    }

    @MainActor
    @Test func importingSamePackageTwiceIsIdempotent() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        var plan = try fixture.importer.preflight(archiveURL: package.archiveURL)
        _ = try fixture.importer.restore(plan: plan, userConfirmed: true)
        plan = try fixture.importer.preflight(archiveURL: package.archiveURL)
        _ = try fixture.importer.restore(plan: plan, userConfirmed: true)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Patient>()) == 1)
        #expect(
            try fixture.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 1
        )
    }

    @MainActor
    @Test func originalRoundTripKeepsHashSizeProtectionAndBackupExclusion() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: true)
        let package = try fixture.exporter.export(scope: .allMembers)
        let plan = try fixture.importer.preflight(
            archiveURL: package.archiveURL
        )
        _ = try fixture.importer.restore(plan: plan, userConfirmed: true)
        let attachment = try #require(
            fixture.context.fetch(FetchDescriptor<Attachment>()).first
        )
        let url = fixture.vault.rootURL.appendingPathComponent(
            attachment.originalRelativePath
        )
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isExcludedFromBackupKey]
        )
        #expect(Int64(values.fileSize ?? -1) == attachment.byteCount)
        #expect(try BackupExporter.sha256(url) == attachment.sha256)
        #expect(values.isExcludedFromBackup == true)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.immutable]
                as? Bool) == true
        )
    }

    @MainActor
    @Test func rollbackAfterVaultSwapLeavesCurrentDatabaseUntouched() throws {
        let fixture = try M8BackupFixture.make(failure: .afterVaultSwap)
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        let plan = try fixture.importer.preflight(
            archiveURL: package.archiveURL
        )
        #expect(throws: BackupError.injectedFailure) {
            try fixture.importer.restore(plan: plan, userConfirmed: true)
        }
        #expect(
            try fixture.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 1
        )
    }

    @MainActor
    @Test func rollbackAfterDatabaseSaveRestoresSnapshot() throws {
        let fixture = try M8BackupFixture.make(failure: .afterDatabaseSave)
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        let plan = try fixture.importer.preflight(archiveURL: package.archiveURL)
        #expect(throws: BackupError.injectedFailure) {
            try fixture.importer.restore(plan: plan, userConfirmed: true)
        }
        #expect(try fixture.context.fetchCount(FetchDescriptor<Patient>()) == 1)
        #expect(
            try fixture.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 1
        )
    }

    @MainActor
    @Test func reopenJournalAfterVaultSwapRestoresPreImportSnapshot() async throws {
        let fixture = try M8BackupFixture.make(
            failure: .simulateInterruptionAfterVaultSwap
        )
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try await fixture.exporter.export(scope: .allMembers)
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Patient>()) == 2)
        let plan = try await fixture.importer.preflight(
            archiveURL: package.archiveURL
        )

        do {
            _ = try await fixture.importer.restore(
                plan: plan,
                userConfirmed: true
            )
            Issue.record("Expected simulated interruption after vault swap")
        } catch let error as BackupError {
            #expect(error == .injectedFailure)
        }
        let journal = fixture.root
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("active.json")
        #expect(FileManager.default.fileExists(atPath: journal.path))

        try await fixture.makeImporter().recoverInterruptedRestoreIfNeeded()
        #expect(try fixture.context.fetchCount(FetchDescriptor<Patient>()) == 2)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @MainActor
    @Test func reopenJournalAfterDatabaseSaveRestoresPreImportSnapshot() async throws {
        let fixture = try M8BackupFixture.make(
            failure: .simulateInterruptionAfterDatabaseSave
        )
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try await fixture.exporter.export(scope: .allMembers)
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let plan = try await fixture.importer.preflight(
            archiveURL: package.archiveURL
        )

        do {
            _ = try await fixture.importer.restore(
                plan: plan,
                userConfirmed: true
            )
            Issue.record("Expected simulated interruption after database save")
        } catch let error as BackupError {
            #expect(error == .injectedFailure)
        }
        #expect(try fixture.context.fetchCount(FetchDescriptor<Patient>()) == 1)
        let journal = fixture.root
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("active.json")
        #expect(FileManager.default.fileExists(atPath: journal.path))

        try await fixture.makeImporter().recoverInterruptedRestoreIfNeeded()
        #expect(try fixture.context.fetchCount(FetchDescriptor<Patient>()) == 2)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @MainActor
    @Test func restoreRequiresExplicitConfirmation() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        let plan = try fixture.importer.preflight(archiveURL: package.archiveURL)
        #expect(throws: BackupError.restoreNotConfirmed) {
            try fixture.importer.restore(plan: plan, userConfirmed: false)
        }
    }

    @MainActor
    @Test func twentyMembersAcceptedAndTwentyOneRejected() throws {
        let accepted = try M8BackupFixture.make()
        _ = try accepted.seedComplete(memberCount: 20, withOriginal: false)
        #expect(try accepted.exporter.export(scope: .allMembers).preview.memberCount == 20)

        let rejected = try M8BackupFixture.make()
        _ = try rejected.seedComplete(memberCount: 21, withOriginal: false)
        #expect(throws: BackupError.memberLimit) {
            try rejected.exporter.export(scope: .allMembers)
        }
    }

    @MainActor
    @Test func tamperedTrackedFileFailsBeforeDatabaseMutation() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        let extracted = try fixture.extract(package.archiveURL)
        let portable = extracted.appendingPathComponent("portable/domain.json")
        try Data("tampered".utf8).write(to: portable)
        let bad = try fixture.zip(extracted)
        #expect(throws: BackupError.integrityMismatch) {
            try fixture.importer.preflight(archiveURL: bad)
        }
        #expect(
            try fixture.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 1
        )
    }

    @MainActor
    @Test func tamperedManifestCountFailsBeforeRestore() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        let extracted = try fixture.extract(package.archiveURL)
        let manifestURL = extracted.appendingPathComponent("manifest.json")
        let manifest = try StableJSON.decode(
            BackupManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let bad = BackupManifest(
            backupID: manifest.backupID,
            exportedAt: manifest.exportedAt,
            scope: manifest.scope,
            memberNames: manifest.memberNames,
            entityCounts: manifest.entityCounts.merging(["medicalRecords": 99]) {
                _, new in new
            },
            files: manifest.files
        )
        try StableJSON.encode(bad).write(to: manifestURL)
        let archive = try fixture.zip(extracted)
        #expect(throws: BackupError.manifestCountMismatch) {
            try fixture.importer.preflight(archiveURL: archive)
        }
    }

    @MainActor
    @Test func truncatedArchiveIsRejected() throws {
        let fixture = try M8BackupFixture.make()
        _ = try fixture.seedComplete(memberCount: 1, withOriginal: false)
        let package = try fixture.exporter.export(scope: .allMembers)
        let data = try Data(contentsOf: package.archiveURL)
        let truncated = fixture.root.appendingPathComponent("truncated.zip")
        try data.prefix(max(1, data.count / 3)).write(to: truncated)
        #expect(throws: BackupError.unsupportedArchive) {
            try fixture.importer.preflight(archiveURL: truncated)
        }
    }

    @MainActor
    @Test func zipSlipPathIsRejected() throws {
        let fixture = try M8BackupFixture.make()
        let archive = fixture.root.appendingPathComponent("slip.zip")
        let zip = try Archive(url: archive, accessMode: .create)
        let bytes = Data("bad".utf8)
        try zip.addEntry(
            with: "../escape",
            type: .file,
            uncompressedSize: Int64(bytes.count),
            provider: { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        #expect(throws: BackupError.unsafePath) {
            try fixture.importer.preflight(archiveURL: archive)
        }
    }

    @MainActor
    @Test func symbolicLinkEntryIsRejected() throws {
        let fixture = try M8BackupFixture.make()
        let archive = fixture.root.appendingPathComponent("symlink.zip")
        let zip = try Archive(url: archive, accessMode: .create)
        let bytes = Data("target".utf8)
        try zip.addEntry(
            with: "link",
            type: .symlink,
            uncompressedSize: Int64(bytes.count),
            provider: { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        #expect(throws: BackupError.symbolicLink) {
            try fixture.importer.preflight(archiveURL: archive)
        }
    }

    @MainActor
    @Test func duplicateArchiveEntryIsRejected() throws {
        let fixture = try M8BackupFixture.make()
        let archive = fixture.root.appendingPathComponent("duplicate.zip")
        let zip = try Archive(url: archive, accessMode: .create)
        let bytes = Data("{}".utf8)
        for _ in 0..<2 {
            try zip.addEntry(
                with: "manifest.json",
                type: .file,
                uncompressedSize: Int64(bytes.count),
                provider: { position, size in
                    bytes.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
        #expect(throws: BackupError.duplicateEntry) {
            try fixture.importer.preflight(archiveURL: archive)
        }
    }

    @MainActor
    @Test func extremeCompressionRatioIsRejected() throws {
        let fixture = try M8BackupFixture.make()
        let archive = fixture.root.appendingPathComponent("bomb.zip")
        let zip = try Archive(url: archive, accessMode: .create)
        let bytes = Data(repeating: 0, count: 2 * 1_024 * 1_024)
        try zip.addEntry(
            with: "portable/domain.json",
            type: .file,
            uncompressedSize: Int64(bytes.count),
            compressionMethod: .deflate,
            provider: { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        #expect(throws: BackupError.suspiciousCompression) {
            try fixture.importer.preflight(archiveURL: archive)
        }
    }

    @Test func pathPolicyRejectsAbsoluteTraversalBackslashAndEmptyComponents() {
        #expect(!BackupPathPolicy.isSafeRelativePath("/private/data"))
        #expect(!BackupPathPolicy.isSafeRelativePath("../data"))
        #expect(!BackupPathPolicy.isSafeRelativePath("a/../data"))
        #expect(!BackupPathPolicy.isSafeRelativePath("a\\data"))
        #expect(!BackupPathPolicy.isSafeRelativePath("a//data"))
        #expect(BackupPathPolicy.isSafeRelativePath("records/id.json"))
    }

    @Test func portableJSONUsesSymmetric128MiBHardBoundary() throws {
        try BackupLimits.validatePortableJSONByteCount(
            BackupLimits.maximumPortableJSONBytes
        )
        #expect(throws: BackupError.archiveTooLarge) {
            try BackupLimits.validatePortableJSONByteCount(
                BackupLimits.maximumPortableJSONBytes + 1
            )
        }
    }

    @Test func manifestValidationRejectsDuplicateDeclaredFiles() {
        let file = BackupFileEntry(
            relativePath: "portable/domain.json",
            byteCount: 1,
            sha256: String(repeating: "a", count: 64)
        )
        let manifest = BackupManifest(
            backupID: UUID(),
            exportedAt: Date(),
            scope: .allMembers,
            memberNames: ["虚构成员"],
            entityCounts: ["patients": 1],
            files: [file, file]
        )
        #expect(throws: BackupError.invalidManifest) {
            try manifest.validate()
        }
    }
}

@Suite(.serialized)
struct M8AppLockTests {
    @MainActor
    @Test func disabledPreferenceStartsWithoutLock() {
        let preferences = M8LockPreferences(false)
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(),
            preferences: preferences
        )
        #expect(controller.phase == .disabled)
        #expect(!controller.isEnabled)
    }

    @MainActor
    @Test func enabledPreferenceStartsLocked() {
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(),
            preferences: M8LockPreferences(true)
        )
        #expect(controller.phase == .locked)
        #expect(controller.isEnabled)
    }

    @MainActor
    @Test func successfulUnlockTransitionsToUnlocked() async {
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(results: [.success]),
            preferences: M8LockPreferences(true)
        )
        #expect(await controller.unlock())
        #expect(controller.phase == .unlocked)
    }

    @MainActor
    @Test func failedUnlockCanRetrySuccessfully() async {
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(
                results: [.failure, .success]
            ),
            preferences: M8LockPreferences(true)
        )
        #expect(!(await controller.unlock()))
        #expect(controller.phase == .failed)
        #expect(await controller.unlock())
        #expect(controller.phase == .unlocked)
    }

    @MainActor
    @Test func cancelledUnlockCanRetry() async {
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(
                results: [.cancelled, .success]
            ),
            preferences: M8LockPreferences(true)
        )
        #expect(!(await controller.unlock()))
        #expect(controller.phase == .failed)
        #expect(await controller.unlock())
    }

    @MainActor
    @Test func enableRequiresSuccessfulSystemAuthentication() async {
        let preferences = M8LockPreferences(false)
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(results: [.success]),
            preferences: preferences
        )
        #expect(await controller.setEnabled(true))
        #expect(preferences.isEnabled)
        #expect(controller.phase == .unlocked)
    }

    @MainActor
    @Test func failedEnableDoesNotPersist() async {
        let preferences = M8LockPreferences(false)
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(results: [.failure]),
            preferences: preferences
        )
        #expect(!(await controller.setEnabled(true)))
        #expect(!preferences.isEnabled)
        #expect(!controller.isEnabled)
    }

    @MainActor
    @Test func unavailableDeviceOwnerAuthenticationCannotEnable() async {
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(
                available: false,
                results: []
            ),
            preferences: M8LockPreferences(false)
        )
        #expect(!controller.canEnable)
        #expect(!(await controller.setEnabled(true)))
    }

    @MainActor
    @Test func backgroundLifecycleRelocksUnlockedApp() async {
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(results: [.success]),
            preferences: M8LockPreferences(true)
        )
        #expect(await controller.unlock())
        controller.lockForPrivacy()
        #expect(controller.phase == .locked)
    }

    @MainActor
    @Test func disablingClearsLockWithoutChangingDisplayMode() async {
        let preferences = M8LockPreferences(true)
        let controller = AppLockController(
            authenticator: DebugLocalAuthenticationAdapter(),
            preferences: preferences
        )
        #expect(await controller.setEnabled(false))
        #expect(controller.phase == .disabled)
        #expect(!preferences.isEnabled)
    }
}

private final class M8LockPreferences: AppLockPreferenceStoring {
    var isEnabled: Bool
    init(_ isEnabled: Bool) { self.isEnabled = isEnabled }
}

@MainActor
private struct M8BackupFixture {
    let root: URL
    let container: ModelContainer
    let context: ModelContext
    let vault: CaptureVaultService
    let exporter: BackupExporter
    let importer: BackupImporter

    static func make(
        failure: BackupRestoreFailurePoint = .none
    ) throws -> M8BackupFixture {
        let root = try TestSupport.temporaryDirectory()
        let container = try TestSupport.container()
        let context = container.mainContext
        let vault = try CaptureVaultService(
            rootURL: root.appendingPathComponent("Vault", isDirectory: true)
        )
        return M8BackupFixture(
            root: root,
            container: container,
            context: context,
            vault: vault,
            exporter: BackupExporter(
                context: context,
                vault: vault,
                temporaryRoot: root.appendingPathComponent("exports")
            ),
            importer: BackupImporter(
                context: context,
                vault: vault,
                temporaryRoot: root.appendingPathComponent("imports"),
                recoveryRoot: root.appendingPathComponent("recovery"),
                failurePoint: failure
            )
        )
    }

    func makeImporter(
        failure: BackupRestoreFailurePoint = .none
    ) -> BackupImporter {
        BackupImporter(
            context: context,
            vault: vault,
            temporaryRoot: root.appendingPathComponent("imports"),
            recoveryRoot: root.appendingPathComponent("recovery"),
            failurePoint: failure
        )
    }

    @discardableResult
    func seedComplete(
        memberCount: Int,
        withOriginal: Bool,
        recordTitle: String = "虚构检查"
    ) throws -> [Patient] {
        var patients: [Patient] = []
        for index in 0..<memberCount {
            let patient = Patient(
                displayName: "虚构成员\(index)",
                aliases: ["测试\(index)"],
                conditions: ["虚构病种"],
                careQuestions: [
                    CareQuestion(
                        text: "下次复查要带什么？",
                        status: .answered,
                        answer: "携带既往虚构报告",
                        note: "仅用于自动化测试"
                    )
                ]
            )
            context.insert(patient)
            let recordID = UUID()
            var attachments: [Attachment] = []
            if withOriginal && index == 0 {
                let attachmentID = UUID()
                let relative = "members/\(patient.id.uuidString)"
                    + "/records/\(recordID.uuidString)"
                    + "/attachments/\(attachmentID.uuidString)/original.txt"
                let file = vault.rootURL.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let bytes = Data("完全虚构的病历原件".utf8)
                try bytes.write(to: file)
                let sha = Data(SHA256.hash(data: bytes)).hexString
                attachments = [
                    try Attachment.verified(
                        id: attachmentID,
                        patientId: patient.id,
                        recordId: recordID,
                        originalRelativePath: relative,
                        displayFileName: "虚构原件.txt",
                        kind: .image,
                        pageIndex: 0,
                        uniformTypeIdentifier: "public.plain-text",
                        byteCount: Int64(bytes.count),
                        sha256: sha,
                        importSource: .fixture
                    )
                ]
            }
            let title = memberCount == 1 ? recordTitle : "\(recordTitle)\(index)"
            let record = MedicalRecord(
                id: recordID,
                patientId: patient.id,
                type: .lab,
                title: title,
                summary: "完全虚构",
                eventDate: Date(timeIntervalSince1970: 1_700_000_000),
                hospital: "虚构医院🙂",
                sourceType: .fixture,
                reviewStatus: .confirmed,
                attachments: attachments
            )
            context.insert(record)
            context.insert(
                Medication(
                    patientId: patient.id,
                    name: "虚构药物",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
            let reminder = try ReminderSchedule(
                patientId: patient.id,
                kind: .followUp,
                title: "虚构复查",
                schedule: ReminderRule(
                    kind: .once,
                    startAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
            context.insert(reminder)
            context.insert(
                AppleReminderBinding(
                    patientId: patient.id,
                    reminderId: reminder.id,
                    destination: .localNotification
                )
            )
            patients.append(patient)
        }
        try context.save()
        return patients
    }

    func extract(_ archive: URL) throws -> URL {
        let destination = root.appendingPathComponent(
            "extract-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try FileManager.default.unzipItem(at: archive, to: destination)
        return destination
    }

    func zip(_ directory: URL) throws -> URL {
        let destination = root.appendingPathComponent(
            "edited-\(UUID().uuidString).zip"
        )
        try FileManager.default.zipItem(
            at: directory,
            to: destination,
            shouldKeepParent: false
        )
        return destination
    }

    func archive(
        replacingPortablePayload payload: BackupPortablePayloadV1,
        in package: BackupExportPackage
    ) throws -> URL {
        let extracted = try extract(package.archiveURL)
        let payloadURL = extracted.appendingPathComponent("portable/domain.json")
        let bytes = try StableJSON.encode(payload)
        try bytes.write(to: payloadURL, options: [.atomic, .completeFileProtection])

        let manifestURL = extracted.appendingPathComponent("manifest.json")
        let manifest = try StableJSON.decode(
            BackupManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let files = manifest.files.map { file in
            guard file.relativePath == "portable/domain.json" else { return file }
            return BackupFileEntry(
                relativePath: file.relativePath,
                byteCount: Int64(bytes.count),
                sha256: Data(SHA256.hash(data: bytes)).hexString
            )
        }
        let updated = BackupManifest(
            backupID: manifest.backupID,
            exportedAt: manifest.exportedAt,
            scope: manifest.scope,
            memberNames: manifest.memberNames,
            entityCounts: manifest.entityCounts,
            files: files
        )
        try StableJSON.encode(updated).write(
            to: manifestURL,
            options: [.atomic, .completeFileProtection]
        )
        return try zip(extracted)
    }
}
