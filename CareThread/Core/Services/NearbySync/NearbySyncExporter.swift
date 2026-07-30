import CryptoKit
import Foundation
import SwiftData

struct NearbySyncExportPreview: Equatable, Sendable {
    let transferID: UUID
    let scope: TransferScope
    let memberCount: Int
    let recordCount: Int
    let attachmentCount: Int
    let entityCount: Int
    let fileCount: Int
    let totalByteCount: Int64
}

final class NearbySyncExportPackage: @unchecked Sendable {
    let manifest: TransferManifest
    let fileURLs: [UUID: URL]
    let preview: NearbySyncExportPreview
    private let temporaryDirectory: URL
    private let fileManager: FileManager

    init(
        manifest: TransferManifest,
        fileURLs: [UUID: URL],
        preview: NearbySyncExportPreview,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) {
        self.manifest = manifest
        self.fileURLs = fileURLs
        self.preview = preview
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    func fileURL(for fileID: UUID) throws -> URL {
        guard let url = fileURLs[fileID] else {
            throw NearbySyncError.incompleteTransfer
        }
        return url
    }

    func cleanup() {
        try? fileManager.removeItem(at: temporaryDirectory)
    }

    deinit {
        cleanup()
    }
}

@MainActor
final class NearbySyncExporter {
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
                "CareThreadNearbySync",
                isDirectory: true
            )
    }

    func preview(scope: TransferScope) throws -> NearbySyncExportPreview {
        let snapshots = try collectSnapshots(scope: scope)
        let originals = try verifiedOriginals(for: snapshots)
        let domainBytes = try snapshots.reduce(into: Int64(0)) {
            $0 += Int64(try $1.envelopeData().count)
        }
        let originalBytes = originals.reduce(into: Int64(0)) { $0 += $1.byteCount }
        let total = try checkedTotal(domainBytes, originalBytes)
        return makePreview(
            transferID: UUID(),
            scope: scope,
            snapshots: snapshots,
            totalBytes: total
        )
    }

    func prepare(
        scope: TransferScope,
        transferID: UUID = UUID(),
        now: Date = Date()
    ) throws -> NearbySyncExportPackage {
        let snapshots = try collectSnapshots(scope: scope)
        let originals = try verifiedOriginals(for: snapshots)
        let directory = temporaryRoot.appendingPathComponent(
            transferID.uuidString.lowercased(),
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directory.path) {
            throw NearbySyncError.unsupportedEntity("迁移暂存标识已存在")
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(resource)

        var entities: [TransferEntityDescriptor] = []
        var files: [TransferFileDescriptor] = []
        var fileURLs: [UUID: URL] = [:]
        do {
            for snapshot in snapshots {
                let payloadFileID = NearbySyncStableID.derive(
                    snapshot.entityID,
                    label: "domain:\(snapshot.kind.rawValue)"
                )
                let data = try snapshot.envelopeData()
                let url = directory
                    .appendingPathComponent(payloadFileID.uuidString.lowercased())
                    .appendingPathExtension("json")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                entities.append(
                    TransferEntityDescriptor(
                        kind: snapshot.kind,
                        entityID: snapshot.entityID,
                        patientID: snapshot.patientID,
                        payloadFileID: payloadFileID,
                        revision: snapshot.revision
                    )
                )
                files.append(
                    TransferFileDescriptor(
                        kind: .domainSnapshot,
                        fileID: payloadFileID,
                        patientID: snapshot.patientID,
                        relativePath: "members/\(snapshot.patientID.uuidString.lowercased())"
                            + "/entities/\(payloadFileID.uuidString.lowercased()).json",
                        byteCount: Int64(data.count),
                        sha256: Data(SHA256.hash(data: data)).hexString
                    )
                )
                fileURLs[payloadFileID] = url
            }
            for original in originals {
                files.append(
                    TransferFileDescriptor(
                        kind: .originalAttachment,
                        fileID: original.attachmentID,
                        patientID: original.patientID,
                        ownerAttachmentID: original.attachmentID,
                        relativePath: "members/\(original.patientID.uuidString.lowercased())"
                            + "/originals/\(original.attachmentID.uuidString.lowercased())"
                            + ".\(original.safeExtension)",
                        byteCount: original.byteCount,
                        sha256: original.sha256
                    )
                )
                fileURLs[original.attachmentID] = original.url
            }
            let manifest = TransferManifest(
                transferID: transferID,
                scope: scope,
                createdAtUTC: ISO8601DateFormatter().string(from: now),
                capabilities: [
                    TransferCapability(identifier: "domain.json", version: 1),
                    NearbySyncContract.capability
                ],
                preview: TransferPreviewCounts(
                    memberCount: snapshots.filter { $0.kind == .patient }.count,
                    recordCount: snapshots.filter { $0.kind == .medicalRecord }.count,
                    attachmentCount: snapshots.filter { $0.kind == .attachment }.count
                ),
                entities: entities,
                files: files
            )
            try manifest.validate()
            guard manifest.totalByteCount <= NearbySyncContract.maximumTransferBytes else {
                throw TransferProtocolError.limitExceeded("4 GiB application transfer")
            }
            let preview = makePreview(
                transferID: transferID,
                scope: scope,
                snapshots: snapshots,
                totalBytes: manifest.totalByteCount
            )
            return NearbySyncExportPackage(
                manifest: manifest,
                fileURLs: fileURLs,
                preview: preview,
                temporaryDirectory: directory,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// Used by receiver preflight to distinguish a safe replay from a UUID
    /// collision. Fingerprints use the same canonical envelope bytes as export.
    func currentFingerprints() throws -> [UUID: String] {
        let snapshots = try collectSnapshots(scope: .allPatients, allowEmpty: true)
        return try Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.entityID, try $0.fingerprint()) }
        )
    }

    private func collectSnapshots(
        scope: TransferScope,
        allowEmpty: Bool = false
    ) throws -> [NearbySyncEntitySnapshot] {
        let patients: [Patient]
        switch scope {
        case let .singlePatient(id):
            var descriptor = FetchDescriptor<Patient>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            patients = try context.fetch(descriptor)
            guard patients.count == 1 else {
                throw NearbySyncError.unsupportedEntity("找不到所选成员")
            }
        case .allPatients:
            var descriptor = FetchDescriptor<Patient>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
            descriptor.fetchLimit = TransferLimits.maximumMembers + 1
            patients = try context.fetch(descriptor)
            guard allowEmpty || !patients.isEmpty else {
                throw NearbySyncError.unsupportedEntity("没有可迁移的成员")
            }
            guard patients.count <= TransferLimits.maximumMembers else {
                throw NearbySyncError.memberLimit
            }
        }
        let patientIDs = Set(patients.map(\.id))
        var snapshots = patients.map(NearbySyncSnapshotFactory.make)

        for patientID in patientIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let records: [MedicalRecord] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let attachments: [Attachment] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let medications: [Medication] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let orders: [MedicalOrder] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let followUps: [FollowUp] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let measurements: [LabMeasurement] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let reminders: [ReminderSchedule] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let audits: [RecordAssignmentAudit] = try fetch(
                predicate: #Predicate {
                    $0.assignedPatientId == patientID
                        || (
                            $0.assignedPatientId == nil
                                && $0.capturedForPatientId == patientID
                        )
                }
            )
            let tags: [RecordTag] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            let revisions: [ContentRevision] = try fetch(
                predicate: #Predicate { $0.patientId == patientID }
            )
            snapshots.append(contentsOf: records.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: try attachments.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: medications.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: orders.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: followUps.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: measurements.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: reminders.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: try audits.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: tags.map(NearbySyncSnapshotFactory.make))
            snapshots.append(contentsOf: try revisions.map(NearbySyncSnapshotFactory.make))
        }
        guard snapshots.count <= TransferLimits.maximumEntities else {
            throw TransferProtocolError.limitExceeded("entities")
        }
        try validateClosure(snapshots, patientIDs: patientIDs)
        return snapshots.sorted {
            ($0.kind.rawValue, $0.entityID.uuidString)
                < ($1.kind.rawValue, $1.entityID.uuidString)
        }
    }

    private func fetch<T: PersistentModel>(
        predicate: Predicate<T>
    ) throws -> [T] {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = TransferLimits.maximumEntities + 1
        let result = try context.fetch(descriptor)
        guard result.count <= TransferLimits.maximumEntities else {
            throw TransferProtocolError.limitExceeded("entities")
        }
        return result
    }

    private func validateClosure(
        _ snapshots: [NearbySyncEntitySnapshot],
        patientIDs: Set<UUID>
    ) throws {
        let pairs = snapshots.map { ($0.entityID, $0) }
        guard Set(pairs.map(\.0)).count == pairs.count else {
            throw NearbySyncError.unsupportedEntity("不同类型资料使用了相同 UUID")
        }
        let byID = Dictionary(uniqueKeysWithValues: pairs)
        for snapshot in snapshots {
            guard patientIDs.contains(snapshot.patientID) else {
                throw NearbySyncError.relationshipClosure(snapshot.entityID)
            }
            for reference in snapshot.references {
                guard let target = byID[reference.entityID],
                      target.kind == reference.kind,
                      target.patientID == snapshot.patientID else {
                    throw NearbySyncError.relationshipClosure(snapshot.entityID)
                }
            }
        }
    }

    private struct VerifiedOriginal {
        let attachmentID: UUID
        let patientID: UUID
        let url: URL
        let byteCount: Int64
        let sha256: String
        let safeExtension: String
    }

    private func verifiedOriginals(
        for snapshots: [NearbySyncEntitySnapshot]
    ) throws -> [VerifiedOriginal] {
        try snapshots.compactMap { snapshot -> VerifiedOriginal? in
            guard snapshot.kind == .attachment,
                  let relativePath = snapshot.originalRelativePath,
                  let body = snapshot.payload.attachment else {
                return nil
            }
            let url: URL
            do {
                url = try vault.url(for: relativePath)
            } catch {
                throw NearbySyncError.missingOriginal(snapshot.entityID)
            }
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true else {
                throw NearbySyncError.missingOriginal(snapshot.entityID)
            }
            guard Int64(values?.fileSize ?? -1) == body.byteCount else {
                throw NearbySyncError.originalChanged(snapshot.entityID)
            }
            let digest = try TransferFileHashing.sha256(url: url)
            guard digest == body.sha256.lowercased() else {
                throw NearbySyncError.originalChanged(snapshot.entityID)
            }
            let ext = url.pathExtension.lowercased()
            let safe = ["jpg", "jpeg", "png", "heic", "pdf"].contains(ext)
                ? ext
                : (body.kind == .pdf ? "pdf" : "jpg")
            return VerifiedOriginal(
                attachmentID: snapshot.entityID,
                patientID: snapshot.patientID,
                url: url,
                byteCount: body.byteCount,
                sha256: digest,
                safeExtension: safe
            )
        }
    }

    private func checkedTotal(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= NearbySyncContract.maximumTransferBytes else {
            throw TransferProtocolError.limitExceeded("4 GiB application transfer")
        }
        return sum
    }

    private func makePreview(
        transferID: UUID,
        scope: TransferScope,
        snapshots: [NearbySyncEntitySnapshot],
        totalBytes: Int64
    ) -> NearbySyncExportPreview {
        NearbySyncExportPreview(
            transferID: transferID,
            scope: scope,
            memberCount: snapshots.filter { $0.kind == .patient }.count,
            recordCount: snapshots.filter { $0.kind == .medicalRecord }.count,
            attachmentCount: snapshots.filter { $0.kind == .attachment }.count,
            entityCount: snapshots.count,
            fileCount: snapshots.count
                + snapshots.filter { $0.kind == .attachment }.count,
            totalByteCount: totalBytes
        )
    }
}

enum NearbySyncStableID {
    static func derive(_ namespace: UUID, label: String) -> UUID {
        var namespaceBytes = namespace.uuid
        var data = withUnsafeBytes(of: &namespaceBytes) { Data($0) }
        data.append(Data(label.utf8))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeMutableBufferPointer {
            NSUUID(uuidBytes: $0.baseAddress!) as UUID
        }
    }
}
