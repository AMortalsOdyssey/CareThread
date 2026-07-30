import CryptoKit
import Foundation
import SwiftData
import ZIPFoundation

struct BackupOriginalExportSource: Sendable {
    let attachmentID: UUID
    let patientID: UUID
    let originalRelativePath: String
    let byteCount: Int64
    let sha256: String
}

struct BackupExportSnapshot: Sendable {
    let payload: BackupPortablePayloadV1
    let originals: [BackupOriginalExportSource]
}

@MainActor
final class BackupExporter {
    private let context: ModelContext
    private let vault: CaptureVaultService
    private let fileManager: FileManager
    private let temporaryRoot: URL

    init(
        context: ModelContext,
        vault: CaptureVaultService,
        temporaryRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.context = context
        self.vault = vault
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "CareThreadBackup",
                isDirectory: true
            )
    }

    func export(
        scope: BackupScope,
        now: Date = Date()
    ) throws -> BackupExportPackage {
        let snapshot = try collectExportSnapshot(scope: scope)
        return try Self.writePackage(
            snapshot: snapshot,
            scope: scope,
            now: now,
            vaultRoot: vault.rootURL,
            temporaryRoot: temporaryRoot,
            fileManager: fileManager
        )
    }

    /// Production export path. SwiftData is snapshotted on MainActor; JSON,
    /// hashing, original copying and ZIP creation run on a detached worker.
    func export(
        scope: BackupScope,
        now: Date = Date()
    ) async throws -> BackupExportPackage {
        let snapshot = try collectExportSnapshot(scope: scope)
        let vaultRoot = vault.rootURL
        let temporaryRoot = temporaryRoot
        return try await runBackupWorker {
            try Task.checkCancellation()
            return try Self.writePackage(
                snapshot: snapshot,
                scope: scope,
                now: now,
                vaultRoot: vaultRoot,
                temporaryRoot: temporaryRoot,
                fileManager: .default
            )
        }
    }

    private nonisolated static func writePackage(
        snapshot: BackupExportSnapshot,
        scope: BackupScope,
        now: Date,
        vaultRoot: URL,
        temporaryRoot: URL,
        fileManager: FileManager
    ) throws -> BackupExportPackage {
        let backupID = UUID()
        let packageRoot = temporaryRoot.appendingPathComponent(
            backupID.uuidString.lowercased(),
            isDirectory: true
        )
        let contentRoot = packageRoot.appendingPathComponent(
            "CareThread-Backup",
            isDirectory: true
        )
        try prepareProtectedDirectory(contentRoot, fileManager: fileManager)
        do {
            try Task.checkCancellation()
            let payload = snapshot.payload
            let counts = entityCounts(payload)
            let patients = payload.entities.compactMap(\.patient)
            guard !patients.isEmpty, patients.count <= BackupLimits.maximumMembers else {
                throw patients.isEmpty ? BackupError.invalidManifest : BackupError.memberLimit
            }

            var files: [BackupFileEntry] = []
            try writePortableAndReadableFiles(
                payload: payload,
                root: contentRoot,
                files: &files,
                fileManager: fileManager
            )
            try copyVerifiedOriginals(
                originals: snapshot.originals,
                root: contentRoot,
                vaultRoot: vaultRoot,
                files: &files,
                fileManager: fileManager
            )

            let names = patients.map(\.editable.displayName)
            let manifest = BackupManifest(
                backupID: backupID,
                exportedAt: now,
                scope: scope,
                memberNames: names,
                entityCounts: counts,
                files: files.sorted { $0.relativePath < $1.relativePath }
            )
            try manifest.validate()
            try write(
                manifest,
                to: contentRoot.appendingPathComponent("manifest.json"),
                fileManager: fileManager
            )
            let archive = packageRoot
                .appendingPathComponent("CareThread-Backup-\(Self.day(now)).zip")
            try Task.checkCancellation()
            try fileManager.zipItem(
                at: contentRoot,
                to: archive,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )
            try Task.checkCancellation()
            try harden(archive, fileManager: fileManager)
            let total = manifest.files.reduce(Int64(0)) { $0 + $1.byteCount }
            let preview = BackupPreview(
                backupID: backupID,
                exportedAt: now,
                memberNames: names,
                memberCount: counts["patients"] ?? 0,
                recordCount: counts["medicalRecords"] ?? 0,
                attachmentCount: counts["attachments"] ?? 0,
                totalByteCount: total
            )
            AppLog.data.info("Backup export completed")
            return BackupExportPackage(archiveURL: archive, preview: preview)
        } catch {
            try? fileManager.removeItem(at: packageRoot)
            AppLog.data.error("Backup export failed")
            throw error
        }
    }

    /// Default shareable backup. The temporary readable ZIP is deleted after
    /// authenticated encryption succeeds.
    func exportEncrypted(
        scope: BackupScope,
        password: String,
        now: Date = Date()
    ) throws -> BackupExportPackage {
        let readable = try export(scope: scope, now: now)
        let encrypted = readable.archiveURL
            .deletingPathExtension()
            .appendingPathExtension(BackupEncryption.fileExtension)
        do {
            try BackupEncryption.encrypt(
                zipURL: readable.archiveURL,
                password: password,
                outputURL: encrypted
            )
            try fileManager.removeItem(at: readable.archiveURL)
            let readableRoot = readable.archiveURL.deletingLastPathComponent()
                .appendingPathComponent("CareThread-Backup", isDirectory: true)
            try? fileManager.removeItem(at: readableRoot)
            return BackupExportPackage(
                archiveURL: encrypted,
                preview: readable.preview
            )
        } catch {
            try? fileManager.removeItem(at: encrypted)
            throw error
        }
    }

    /// Production encrypted-export path; PBKDF2 and chunked AEAD never execute
    /// on MainActor.
    func exportEncrypted(
        scope: BackupScope,
        password: String,
        now: Date = Date()
    ) async throws -> BackupExportPackage {
        let readable = try await export(scope: scope, now: now)
        return try await runBackupWorker {
            let encrypted = readable.archiveURL
                .deletingPathExtension()
                .appendingPathExtension(BackupEncryption.fileExtension)
            do {
                try Task.checkCancellation()
                try BackupEncryption.encrypt(
                    zipURL: readable.archiveURL,
                    password: password,
                    outputURL: encrypted
                )
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: readable.archiveURL)
                let readableRoot = readable.archiveURL.deletingLastPathComponent()
                    .appendingPathComponent("CareThread-Backup", isDirectory: true)
                try? FileManager.default.removeItem(at: readableRoot)
                return BackupExportPackage(
                    archiveURL: encrypted,
                    preview: readable.preview
                )
            } catch {
                try? FileManager.default.removeItem(at: encrypted)
                readable.discard()
                throw error
            }
        }
    }

    func collectPayload(scope: BackupScope) throws -> BackupPortablePayloadV1 {
        try collectExportSnapshot(scope: scope).payload
    }

    private func collectExportSnapshot(
        scope: BackupScope
    ) throws -> BackupExportSnapshot {
        let patients = try selectedPatients(scope)
        let patientIDs = Set(patients.map(\.id))
        guard patients.count <= BackupLimits.maximumMembers else {
            throw BackupError.memberLimit
        }
        var entities = patients.map {
            NearbySyncSnapshotFactory.make($0).payload
        }
        var batches: [BackupImportBatchDTO] = []
        var drafts: [BackupCaptureDraftDTO] = []
        var pages: [BackupCapturePageDTO] = []
        var bindings: [BackupAppleReminderBindingDTO] = []
        var revisions: [BackupContentRevisionDTO] = []

        // One materialization per entity type. The previous implementation
        // fetched every table once per selected member, producing O(P*N)
        // allocations at the 20-member limit.
        let allRecords = try context.fetch(FetchDescriptor<MedicalRecord>())
            .filter { patientIDs.contains($0.patientId) }
        let allAttachments = try context.fetch(FetchDescriptor<Attachment>())
            .filter { patientIDs.contains($0.patientId) }
        let allMedications = try context.fetch(FetchDescriptor<Medication>())
            .filter { patientIDs.contains($0.patientId) }
        let allOrders = try context.fetch(FetchDescriptor<MedicalOrder>())
            .filter { patientIDs.contains($0.patientId) }
        let allFollowUps = try context.fetch(FetchDescriptor<FollowUp>())
            .filter { patientIDs.contains($0.patientId) }
        let allMeasurements = try context.fetch(FetchDescriptor<LabMeasurement>())
            .filter { patientIDs.contains($0.patientId) }
        let allReminders = try context.fetch(FetchDescriptor<ReminderSchedule>())
            .filter { patientIDs.contains($0.patientId) }
        let allTags = try context.fetch(FetchDescriptor<RecordTag>())
            .filter { patientIDs.contains($0.patientId) }
        let allAudits = try context.fetch(FetchDescriptor<RecordAssignmentAudit>())
            .filter {
                if let assigned = $0.assignedPatientId {
                    return patientIDs.contains(assigned)
                }
                return patientIDs.contains($0.capturedForPatientId)
            }
        let allBatches = try context.fetch(FetchDescriptor<ImportBatch>())
            .filter { patientIDs.contains($0.patientId) }
        let allDrafts = try context.fetch(FetchDescriptor<CaptureDraft>())
            .filter { patientIDs.contains($0.patientId) }
        let allPages = try context.fetch(FetchDescriptor<CapturePage>())
            .filter { patientIDs.contains($0.patientId) }
        let allBindings = try context.fetch(FetchDescriptor<AppleReminderBinding>())
            .filter { patientIDs.contains($0.patientId) }
        let allRevisions = try context.fetch(FetchDescriptor<ContentRevision>())
            .filter { patientIDs.contains($0.patientId) }

        let recordsByPatient = Dictionary(grouping: allRecords, by: \.patientId)
        let attachmentsByPatient = Dictionary(grouping: allAttachments, by: \.patientId)
        let medicationsByPatient = Dictionary(grouping: allMedications, by: \.patientId)
        let ordersByPatient = Dictionary(grouping: allOrders, by: \.patientId)
        let followUpsByPatient = Dictionary(grouping: allFollowUps, by: \.patientId)
        let measurementsByPatient = Dictionary(grouping: allMeasurements, by: \.patientId)
        let remindersByPatient = Dictionary(grouping: allReminders, by: \.patientId)
        let tagsByPatient = Dictionary(grouping: allTags, by: \.patientId)
        let auditsByPatient = Dictionary(grouping: allAudits) {
            $0.assignedPatientId ?? $0.capturedForPatientId
        }
        let batchesByPatient = Dictionary(grouping: allBatches, by: \.patientId)
        let draftsByPatient = Dictionary(grouping: allDrafts, by: \.patientId)
        let pagesByPatient = Dictionary(grouping: allPages, by: \.patientId)
        let bindingsByPatient = Dictionary(grouping: allBindings, by: \.patientId)
        let revisionsByPatient = Dictionary(grouping: allRevisions, by: \.patientId)

        for patientID in patientIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let records = recordsByPatient[patientID] ?? []
            let attachments = attachmentsByPatient[patientID] ?? []
            let medications = medicationsByPatient[patientID] ?? []
            let orders = ordersByPatient[patientID] ?? []
            let followUps = followUpsByPatient[patientID] ?? []
            let measurements = measurementsByPatient[patientID] ?? []
            let reminders = remindersByPatient[patientID] ?? []
            let tags = tagsByPatient[patientID] ?? []
            let patientAudits = auditsByPatient[patientID] ?? []
            let patientBatches = batchesByPatient[patientID] ?? []
            let patientDrafts = draftsByPatient[patientID] ?? []
            let patientPages = pagesByPatient[patientID] ?? []
            let patientBindings = bindingsByPatient[patientID] ?? []
            let patientRevisions = revisionsByPatient[patientID] ?? []

            entities.append(contentsOf: records.map {
                NearbySyncSnapshotFactory.make($0).payload
            })
            entities.append(contentsOf: try attachments.map {
                try NearbySyncSnapshotFactory.make($0).payload
            })
            entities.append(contentsOf: medications.map {
                NearbySyncSnapshotFactory.make($0).payload
            })
            entities.append(contentsOf: orders.map {
                NearbySyncSnapshotFactory.make($0).payload
            })
            entities.append(contentsOf: followUps.map {
                NearbySyncSnapshotFactory.make($0).payload
            })
            entities.append(contentsOf: measurements.map {
                NearbySyncSnapshotFactory.make($0).payload
            })
            entities.append(contentsOf: reminders.map {
                NearbySyncSnapshotFactory.make($0).payload
            })
            entities.append(contentsOf: tags.map {
                NearbySyncSnapshotFactory.make($0).payload
            })
            let recordIDs = Set(records.map(\.id))
            entities.append(contentsOf: try patientAudits.map {
                try Self.auditPayload(
                    $0,
                    ownerPatientID: patientID,
                    recordIDs: recordIDs
                )
            })

            batches.append(contentsOf: patientBatches.map {
                BackupImportBatchDTO(
                    id: $0.id,
                    patientID: $0.patientId,
                    sourceType: $0.sourceType,
                    stateStatus: $0.status,
                    generation: $0.generation,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            })
            drafts.append(contentsOf: patientDrafts.map {
                BackupCaptureDraftDTO(
                    id: $0.id,
                    patientID: $0.patientId,
                    batchID: $0.batchId,
                    documentIndex: $0.documentIndex,
                    groupingRevision: $0.groupingRevision,
                    generation: $0.generation,
                    titleSuggestion: $0.titleSuggestion,
                    confirmedTitle: $0.confirmedTitle,
                    sourceType: $0.sourceType,
                    attachmentPaths: $0.attachmentPaths,
                    selectedType: $0.selectedType,
                    selectedDate: $0.selectedDate,
                    ocrText: $0.ocrText,
                    machineExtraction: $0.machineExtraction,
                    updatedAt: $0.updatedAt,
                    contentRevision: $0.contentRevision
                )
            })
            pages.append(contentsOf: patientPages.map {
                BackupCapturePageDTO(
                    id: $0.id,
                    patientID: $0.patientId,
                    batchID: $0.batchId,
                    draftID: $0.draftId,
                    sourceOrder: $0.sourceOrder,
                    pageIndex: $0.pageIndex,
                    stagingRelativePath: $0.stagingRelativePath,
                    attachmentID: $0.attachmentId,
                    ocrGeneration: $0.ocrGeneration,
                    ocrStatus: $0.ocrStatus,
                    ocrText: $0.ocrText,
                    detectedNameCandidates: $0.detectedNameCandidates,
                    hospitalSuggestion: $0.hospitalSuggestion,
                    dateSuggestion: $0.dateSuggestion,
                    titleSuggestion: $0.titleSuggestion,
                    pageMarker: $0.pageMarker,
                    overlapFingerprint: $0.overlapFingerprint,
                    confirmedHospital: $0.confirmedHospital,
                    confirmedDate: $0.confirmedDate,
                    confirmedTitle: $0.confirmedTitle,
                    createdAt: $0.createdAt,
                    contentRevision: $0.contentRevision
                )
            })
            bindings.append(contentsOf: patientBindings.map {
                BackupAppleReminderBindingDTO(
                    id: $0.id,
                    patientID: $0.patientId,
                    reminderID: $0.reminderId,
                    destination: $0.destination,
                    localNotificationIdentifier: $0.localNotificationIdentifier,
                    calendarEventIdentifier: $0.calendarEventIdentifier,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            })
            revisions.append(contentsOf: patientRevisions.map {
                BackupContentRevisionDTO(
                    id: $0.id,
                    entityKind: $0.entityKind,
                    entityID: $0.entityId,
                    patientID: $0.patientId,
                    revision: $0.revision,
                    changedFieldKeys: $0.changedFieldKeys,
                    beforeContentPayload: $0.beforeContentPayload,
                    afterContentPayload: $0.afterContentPayload,
                    source: $0.source,
                    actor: $0.actor,
                    createdAt: $0.createdAt
                )
            })
        }
        let uniqueIDs = entities.map(\.entityID)
        guard Set(uniqueIDs).count == uniqueIDs.count else {
            throw BackupError.invalidRelationship
        }
        let payload = BackupPortablePayloadV1(
            schemaVersion: 1,
            entities: entities.sorted {
                ($0.kind.rawValue, $0.entityID.uuidString)
                    < ($1.kind.rawValue, $1.entityID.uuidString)
            },
            importBatches: batches.sorted { $0.id.uuidString < $1.id.uuidString },
            captureDrafts: drafts.sorted { $0.id.uuidString < $1.id.uuidString },
            capturePages: pages.sorted { $0.id.uuidString < $1.id.uuidString },
            appleReminderBindings: bindings.sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            contentRevisions: revisions.sorted {
                $0.id.uuidString < $1.id.uuidString
            }
        )
        let originals = allAttachments.map {
            BackupOriginalExportSource(
                attachmentID: $0.id,
                patientID: $0.patientId,
                originalRelativePath: $0.originalRelativePath,
                byteCount: $0.byteCount,
                sha256: $0.sha256.lowercased()
            )
        }
        return BackupExportSnapshot(payload: payload, originals: originals)
    }

    private func selectedPatients(_ scope: BackupScope) throws -> [Patient] {
        switch scope {
        case let .singleMember(id):
            var descriptor = FetchDescriptor<Patient>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            let values = try context.fetch(descriptor)
            guard values.count == 1 else { throw BackupError.invalidManifest }
            return values
        case .allMembers:
            return try context.fetch(
                FetchDescriptor<Patient>(
                    sortBy: [SortDescriptor(\.createdAt)]
                )
            )
        }
    }

    private nonisolated static func writePortableAndReadableFiles(
        payload: BackupPortablePayloadV1,
        root: URL,
        files: inout [BackupFileEntry],
        fileManager: FileManager
    ) throws {
        try Task.checkCancellation()
        let portableData = try StableJSON.encode(payload)
        try BackupLimits.validatePortableJSONByteCount(Int64(portableData.count))
        try writeTrackedData(
            portableData,
            relativePath: "portable/domain.json",
            root: root,
            files: &files,
            fileManager: fileManager
        )
        let patients = payload.entities.filter { $0.kind == .patient }
        try writeTracked(
            patients,
            relativePath: "patient.json",
            root: root,
            files: &files,
            fileManager: fileManager
        )
        let grouped = Dictionary(grouping: payload.entities, by: \.kind)
        try writeTracked(
            grouped[.medication] ?? [],
            relativePath: "medications.json",
            root: root,
            files: &files,
            fileManager: fileManager
        )
        try writeTracked(
            grouped[.medicalOrder] ?? [],
            relativePath: "orders.json",
            root: root,
            files: &files,
            fileManager: fileManager
        )
        try writeTracked(
            grouped[.followUp] ?? [],
            relativePath: "followups.json",
            root: root,
            files: &files,
            fileManager: fileManager
        )
        try writeTracked(
            grouped[.reminder] ?? [],
            relativePath: "reminders.json",
            root: root,
            files: &files,
            fileManager: fileManager
        )
        for record in grouped[.medicalRecord] ?? [] {
            try Task.checkCancellation()
            let stem = "records/\(record.entityID.uuidString.lowercased())"
            try writeTracked(
                record,
                relativePath: "\(stem).json",
                root: root,
                files: &files,
                fileManager: fileManager
            )
            let markdown = Self.recordMarkdown(record)
            try writeTrackedData(
                Data(markdown.utf8),
                relativePath: "\(stem).md",
                root: root,
                files: &files,
                fileManager: fileManager
            )
        }
    }

    private nonisolated static func copyVerifiedOriginals(
        originals: [BackupOriginalExportSource],
        root: URL,
        vaultRoot: URL,
        files: inout [BackupFileEntry],
        fileManager: FileManager
    ) throws {
        for original in originals {
            try Task.checkCancellation()
            guard BackupPathPolicy.isSafeRelativePath(
                original.originalRelativePath
            ) else {
                throw BackupError.missingOriginal
            }
            let source = vaultRoot.appendingPathComponent(
                original.originalRelativePath
            )
            let values = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == original.byteCount,
                  try Self.sha256(source) == original.sha256 else {
                throw BackupError.integrityMismatch
            }
            let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
            let relative = "attachments/\(original.patientID.uuidString.lowercased())"
                + "/\(original.attachmentID.uuidString.lowercased()).\(ext.lowercased())"
            let destination = root.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try fileManager.copyItem(at: source, to: destination)
            try harden(destination, fileManager: fileManager)
            files.append(
                BackupFileEntry(
                    relativePath: relative,
                    byteCount: original.byteCount,
                    sha256: original.sha256
                )
            )
        }
    }

    private nonisolated static func writeTracked<T: Encodable>(
        _ value: T,
        relativePath: String,
        root: URL,
        files: inout [BackupFileEntry],
        fileManager: FileManager
    ) throws {
        try writeTrackedData(
            try StableJSON.encode(value),
            relativePath: relativePath,
            root: root,
            files: &files,
            fileManager: fileManager
        )
    }

    private nonisolated static func writeTrackedData(
        _ data: Data,
        relativePath: String,
        root: URL,
        files: inout [BackupFileEntry],
        fileManager: FileManager
    ) throws {
        guard BackupPathPolicy.isSafeRelativePath(relativePath) else {
            throw BackupError.unsafePath
        }
        let destination = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        try harden(destination, fileManager: fileManager)
        files.append(
            BackupFileEntry(
                relativePath: relativePath,
                byteCount: Int64(data.count),
                sha256: Data(SHA256.hash(data: data)).hexString
            )
        )
    }

    private nonisolated static func write<T: Encodable>(
        _ value: T,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let data = try StableJSON.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try harden(url, fileManager: fileManager)
    }

    private nonisolated static func prepareProtectedDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try harden(url, fileManager: fileManager)
    }

    private nonisolated static func harden(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutable = url
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try mutable.setResourceValues(resource)
    }

    private nonisolated static func entityCounts(
        _ payload: BackupPortablePayloadV1
    ) -> [String: Int] {
        let grouped = Dictionary(grouping: payload.entities, by: \.kind)
        return [
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
    }

    private static func auditPayload(
        _ audit: RecordAssignmentAudit,
        ownerPatientID: UUID,
        recordIDs: Set<UUID>
    ) throws -> NearbySyncEntityPayloadV1 {
        let recordID: UUID
        do {
            recordID = try RecordAssignmentTransferPolicy.validateStructure(
                capturedForPatientID: audit.capturedForPatientId,
                assignedPatientID: audit.assignedPatientId,
                recordID: audit.recordId,
                outcome: audit.outcome,
                decision: audit.decision,
                overrideReason: audit.overrideReason,
                expectedOwnerPatientID: ownerPatientID
            )
        } catch {
            throw BackupError.invalidRelationship
        }
        guard recordIDs.contains(recordID) else {
            throw BackupError.invalidRelationship
        }
        return NearbySyncEntityPayloadV1(
            kind: .assignmentAudit,
            entityID: audit.id,
            patientID: ownerPatientID,
            assignmentAudit: .init(
                capturedForPatientID: audit.capturedForPatientId,
                assignedPatientID: audit.assignedPatientId,
                draftID: audit.draftId,
                recordID: recordID,
                detectedName: audit.detectedName,
                outcome: audit.outcome,
                decision: audit.decision,
                overrideReason: audit.overrideReason,
                engineIdentifier: audit.engineIdentifier,
                engineVersion: audit.engineVersion,
                createdAt: audit.createdAt
            )
        )
    }

    private nonisolated static func recordMarkdown(
        _ payload: NearbySyncEntityPayloadV1
    ) -> String {
        guard let body = payload.medicalRecord else { return "" }
        let editable = body.editable
        let date = ISO8601DateFormatter().string(from: editable.eventDate)
        let safeTitle = editable.title.replacingOccurrences(of: "\n", with: " ")
        let safeHospital = (editable.hospital ?? "")
            .replacingOccurrences(of: "\n", with: " ")
        return """
        ---
        id: \(payload.entityID.uuidString)
        member_id: \(payload.patientID.uuidString)
        date: \(date)
        type: \(editable.type.rawValue)
        title: "\(safeTitle.replacingOccurrences(of: "\"", with: "\\\""))"
        hospital: "\(safeHospital.replacingOccurrences(of: "\"", with: "\\\""))"
        ---

        # \(safeTitle.isEmpty ? editable.type.displayName : safeTitle)

        \(editable.summary)

        ## OCR 原文

        \(body.ocrText ?? "无")
        """
    }

    private nonisolated static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return Data(hasher.finalize()).hexString
    }
}
