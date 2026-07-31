import CryptoKit
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

enum CaptureVaultError: Error, Equatable {
    case invalidBatch
    case unsupportedType
    case sourceMissing
    case fileTooLarge
    case imageDimensionsTooLarge
    case invalidImage
    case invalidRelativePath
    case finalDestinationExists
    case journalCorrupted
    case backupExclusionFailed
    case integrityMismatch
}

struct CapturePreviewDimensions: Equatable {
    let width: Int
    let height: Int
}

enum CaptureImagePreviewPolicy {
    static func targetDimensions(
        width: Int,
        height: Int,
        maximumDimension: Int = CaptureVaultService.workingImageMaximumPixelSize,
        downsampleThresholdPixels: Int =
            CaptureVaultService.workingImageDownsampleThresholdPixels
    ) -> CapturePreviewDimensions {
        guard width > 0,
              height > 0,
              maximumDimension > 0,
              downsampleThresholdPixels > 0 else {
            return CapturePreviewDimensions(width: 0, height: 0)
        }
        let longest = max(width, height)
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard overflow
                || pixelCount > downsampleThresholdPixels
                || longest > maximumDimension else {
            return CapturePreviewDimensions(width: width, height: height)
        }
        let scale = Double(maximumDimension) / Double(longest)
        return CapturePreviewDimensions(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }
}

struct StagedCaptureAsset: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let batchID: UUID
    let originalRelativePath: String
    let previewRelativePath: String?
    let displayName: String
    let fileExtension: String
    let uniformTypeIdentifier: String
    let kind: AttachmentKind
    let byteCount: Int64
    let sha256: String
    let pixelWidth: Int?
    let pixelHeight: Int?
    let pageCount: Int?
    let createdAt: Date
}

struct CaptureFinalizationTransaction: Codable, Equatable {
    enum State: String, Codable {
        case prepared
        case filesMoved
        case databaseCommitted
    }

    let assetID: UUID
    let patientID: UUID
    let recordID: UUID
    let stagedOriginalRelativePath: String
    let stagedPreviewRelativePath: String?
    let finalOriginalRelativePath: String
    let finalPreviewRelativePath: String?
    var state: State
}

struct CaptureVaultJournal: Codable, Equatable {
    enum State: String, Codable {
        case staging
        case readyForReview
        case partiallyFinalized
        case completed
        case recoverableFailure
    }

    let schemaVersion: Int
    let batchID: UUID
    var state: State
    var assets: [StagedCaptureAsset]
    var finalizedAssetIDs: [UUID]
    var finalizationTransactions: [CaptureFinalizationTransaction]
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case batchID
        case state
        case assets
        case finalizedAssetIDs
        case finalizationTransactions
        case updatedAt
    }

    init(
        schemaVersion: Int,
        batchID: UUID,
        state: State,
        assets: [StagedCaptureAsset],
        finalizedAssetIDs: [UUID],
        finalizationTransactions: [CaptureFinalizationTransaction] = [],
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.state = state
        self.assets = assets
        self.finalizedAssetIDs = finalizedAssetIDs
        self.finalizationTransactions = finalizationTransactions
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        batchID = try container.decode(UUID.self, forKey: .batchID)
        state = try container.decode(State.self, forKey: .state)
        assets = try container.decode([StagedCaptureAsset].self, forKey: .assets)
        finalizedAssetIDs = try container.decode(
            [UUID].self,
            forKey: .finalizedAssetIDs
        )
        finalizationTransactions = try container.decodeIfPresent(
            [CaptureFinalizationTransaction].self,
            forKey: .finalizationTransactions
        ) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct FinalizedCaptureAsset: Hashable {
    let staged: StagedCaptureAsset
    let recordID: UUID
    let finalRelativePath: String
    let finalPreviewRelativePath: String?
}

enum CaptureBulkStagingEvent: Sendable, Equatable {
    case started(Int)
    case finished(Int)
}

/// Runs image encoding/data production and Vault staging away from MainActor.
///
/// The provider is invoked serially inside an autorelease pool. This is the
/// memory boundary for camera scans: at most one decoded full-size page and
/// its encoded bytes are live at a time. The returned array contains metadata
/// only; original bytes remain in the protected Vault staging directory.
enum CaptureAssetStagingWorker {
    typealias PageDataProvider = @Sendable (Int) throws -> Data
    typealias DisplayNameProvider = @Sendable (Int) -> String
    typealias Observer = @Sendable (CaptureBulkStagingEvent) -> Void

    static func stagePages(
        count: Int,
        vaultRootURL: URL,
        batchID: UUID,
        preferredExtension: String,
        uniformTypeIdentifier: String,
        displayName: @escaping DisplayNameProvider,
        dataForPage: @escaping PageDataProvider,
        observer: @escaping Observer = { _ in }
    ) async throws -> [StagedCaptureAsset] {
        guard count > 0 else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            let vault = try CaptureVaultService(rootURL: vaultRootURL)
            var staged: [StagedCaptureAsset] = []
            staged.reserveCapacity(count)
            do {
                for index in 0..<count {
                    try Task.checkCancellation()
                    let asset = try autoreleasepool {
                        observer(.started(index))
                        defer { observer(.finished(index)) }
                        let data = try dataForPage(index)
                        try Task.checkCancellation()
                        return try vault.stagePhotoData(
                            data,
                            batchID: batchID,
                            displayName: displayName(index),
                            preferredExtension: preferredExtension,
                            uniformTypeIdentifier: uniformTypeIdentifier
                        )
                    }
                    staged.append(asset)
                }
                try Task.checkCancellation()
                return staged
            } catch {
                try? vault.discardStagedAssets(
                    batchID: batchID,
                    assetIDs: Set(staged.map(\.id))
                )
                throw error
            }
        }.value
    }

    static func stagePhotoData(
        _ data: Data,
        vaultRootURL: URL,
        batchID: UUID,
        displayName: String,
        preferredExtension: String,
        uniformTypeIdentifier: String
    ) async throws -> StagedCaptureAsset {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                return try CaptureVaultService(rootURL: vaultRootURL)
                    .stagePhotoData(
                        data,
                        batchID: batchID,
                        displayName: displayName,
                        preferredExtension: preferredExtension,
                        uniformTypeIdentifier: uniformTypeIdentifier
                    )
            }
        }.value
    }
}

/// Owns the only write path for captured originals.
///
/// Originals first enter a recoverable, batch-scoped staging directory. A
/// confirmed record atomically moves each original into its tenant/record
/// directory. No second "working original" is written.
final class CaptureVaultService {
    static let maximumPhotoBytes: Int64 = 40 * 1_024 * 1_024
    static let maximumFileBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumImageDimension = 16_384
    static let workingImageDownsampleThresholdPixels = 12_000_000
    static let workingImageMaximumPixelSize = 3_000
    static let streamingChunkBytes = 1_024 * 1_024

    let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else if ProcessInfo.processInfo.arguments.contains("-uiTestMode") {
            // UI automation must never touch the user's Application Support
            // Vault. The process-scoped root is discarded with the simulator
            // app process and mirrors the in-memory SwiftData boundary.
            self.rootURL = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "CareThreadUITestVault-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootURL = support.appendingPathComponent("Vault", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFromBackupAndVerify(self.rootURL)
    }

    func beginBatch(_ batchID: UUID) throws {
        let directory = try batchDirectory(batchID)
        let stagingRoot = try resolve("staging")
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFromBackupAndVerify(stagingRoot)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFromBackupAndVerify(directory)
        let journalURL = directory.appendingPathComponent("journal.json")
        guard !fileManager.fileExists(atPath: journalURL.path) else { return }
        try writeJournal(
            CaptureVaultJournal(
                schemaVersion: 1,
                batchID: batchID,
                state: .staging,
                assets: [],
                finalizedAssetIDs: [],
                updatedAt: Date()
            )
        )
    }

    func stagePhotoData(
        _ data: Data,
        batchID: UUID,
        displayName: String,
        preferredExtension: String = "jpg",
        uniformTypeIdentifier: String = UTType.jpeg.identifier
    ) throws -> StagedCaptureAsset {
        guard Int64(data.count) <= Self.maximumPhotoBytes else {
            throw CaptureVaultError.fileTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            throw CaptureVaultError.invalidImage
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        guard let width, let height, width > 0, height > 0 else {
            throw CaptureVaultError.invalidImage
        }
        guard max(width, height) <= Self.maximumImageDimension else {
            throw CaptureVaultError.imageDimensionsTooLarge
        }

        try beginBatch(batchID)
        let id = UUID()
        let ext = try normalizedExtension(preferredExtension)
        let relativePath = "staging/\(batchID.uuidString)/\(id.uuidString)/original.\(ext)"
        let destination = try resolve(relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            try excludeFromBackupAndVerify(destination.deletingLastPathComponent())
            try excludeFromBackupAndVerify(destination)
            let previewPath = try writePreviewIfNeeded(
                source: source,
                batchID: batchID,
                assetID: id,
                width: width,
                height: height
            )
            let asset = StagedCaptureAsset(
                id: id,
                batchID: batchID,
                originalRelativePath: relativePath,
                previewRelativePath: previewPath,
                displayName: displayName,
                fileExtension: ext,
                uniformTypeIdentifier: uniformTypeIdentifier,
                kind: .image,
                byteCount: Int64(data.count),
                sha256: Self.sha256(data),
                pixelWidth: width,
                pixelHeight: height,
                pageCount: nil,
                createdAt: journalTimestamp()
            )
            try appendToJournal(asset)
            return asset
        } catch {
            try? fileManager.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    /// Copies a security-scoped file without loading the entire original into memory.
    func stageFile(
        at sourceURL: URL,
        batchID: UUID,
        displayName: String? = nil
    ) throws -> StagedCaptureAsset {
        let values = try sourceURL.resourceValues(
            forKeys: [.contentTypeKey, .fileSizeKey, .nameKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true else { throw CaptureVaultError.sourceMissing }
        let type = values.contentType ?? UTType(filenameExtension: sourceURL.pathExtension)
        guard let type,
              type.conforms(to: .image) || type.conforms(to: .pdf),
              !type.conforms(to: .movie),
              !type.conforms(to: .audiovisualContent) else {
            throw CaptureVaultError.unsupportedType
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount > 0, byteCount <= Self.maximumFileBytes else {
            throw CaptureVaultError.fileTooLarge
        }
        try beginBatch(batchID)
        let id = UUID()
        let ext = try normalizedExtension(
            type.preferredFilenameExtension ?? sourceURL.pathExtension
        )
        let relativePath = "staging/\(batchID.uuidString)/\(id.uuidString)/original.\(ext)"
        let destination = try resolve(relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: destination.path
            )
            try excludeFromBackupAndVerify(destination.deletingLastPathComponent())
            try excludeFromBackupAndVerify(destination)
            let digest = try Self.sha256File(at: destination)
            let metadata = try imageOrPDFMetadata(
                at: destination,
                type: type,
                batchID: batchID,
                assetID: id
            )
            let asset = StagedCaptureAsset(
                id: id,
                batchID: batchID,
                originalRelativePath: relativePath,
                previewRelativePath: metadata.previewRelativePath,
                displayName: displayName ?? values.name ?? sourceURL.lastPathComponent,
                fileExtension: ext,
                uniformTypeIdentifier: type.identifier,
                kind: type.conforms(to: .pdf) ? .pdf : .image,
                byteCount: byteCount,
                sha256: digest,
                pixelWidth: metadata.width,
                pixelHeight: metadata.height,
                pageCount: metadata.pageCount,
                createdAt: journalTimestamp()
            )
            try appendToJournal(asset)
            return asset
        } catch {
            try? fileManager.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    func journal(batchID: UUID) throws -> CaptureVaultJournal {
        let url = try batchDirectory(batchID).appendingPathComponent("journal.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw CaptureVaultError.invalidBatch
        }
        do {
            return try decoder.decode(
                CaptureVaultJournal.self,
                from: Data(contentsOf: url, options: .mappedIfSafe)
            )
        } catch {
            throw CaptureVaultError.journalCorrupted
        }
    }

    func updateJournalState(batchID: UUID, state: CaptureVaultJournal.State) throws {
        var value = try journal(batchID: batchID)
        value.state = state
        value.updatedAt = Date()
        try writeJournal(value)
    }

    func finalize(
        asset: StagedCaptureAsset,
        patientID: UUID,
        recordID: UUID
    ) throws -> FinalizedCaptureAsset {
        let currentJournal = try journal(batchID: asset.batchID)
        guard currentJournal.batchID == asset.batchID,
              currentJournal.assets.contains(asset),
              !currentJournal.finalizedAssetIDs.contains(asset.id) else {
            throw CaptureVaultError.invalidBatch
        }
        let source = try resolve(asset.originalRelativePath)
        guard fileManager.fileExists(atPath: source.path) else {
            throw CaptureVaultError.sourceMissing
        }
        let sourceSize = try source.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize.map(Int64.init)
        guard sourceSize == asset.byteCount,
              try Self.sha256File(at: source) == asset.sha256 else {
            throw CaptureVaultError.integrityMismatch
        }
        let destinationPath =
            "members/\(patientID.uuidString)/records/\(recordID.uuidString)/attachments/"
            + "\(asset.id.uuidString)/original.\(asset.fileExtension)"
        let destination = try resolve(destinationPath)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CaptureVaultError.finalDestinationExists
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFinalHierarchy(
            patientID: patientID,
            recordID: recordID,
            attachmentID: asset.id
        )
        let previewDestinationPath = asset.previewRelativePath.map { _ in
            "members/\(patientID.uuidString)/records/\(recordID.uuidString)/attachments/"
                + "\(asset.id.uuidString)/preview.jpg"
        }
        let previewSource = try asset.previewRelativePath.map(resolve)
        let previewDestination = try previewDestinationPath.map(resolve)
        var preparedJournal = try journal(batchID: asset.batchID)
        preparedJournal.finalizationTransactions.removeAll {
            $0.assetID == asset.id
        }
        preparedJournal.finalizationTransactions.append(
            CaptureFinalizationTransaction(
                assetID: asset.id,
                patientID: patientID,
                recordID: recordID,
                stagedOriginalRelativePath: asset.originalRelativePath,
                stagedPreviewRelativePath: asset.previewRelativePath,
                finalOriginalRelativePath: destinationPath,
                finalPreviewRelativePath: previewDestinationPath,
                state: .prepared
            )
        )
        preparedJournal.state = .partiallyFinalized
        preparedJournal.updatedAt = Date()
        try writeJournal(preparedJournal)
        var originalMoved = false
        var previewMoved = false
        do {
            try fileManager.moveItem(at: source, to: destination)
            originalMoved = true
            if let previewSource, let previewDestination,
               fileManager.fileExists(atPath: previewSource.path) {
                try fileManager.moveItem(at: previewSource, to: previewDestination)
                previewMoved = true
            }
            try excludeFromBackupAndVerify(destination)
            if previewMoved, let previewDestination {
                try excludeFromBackupAndVerify(previewDestination)
            }
            for url in [destination, previewMoved ? previewDestination : nil].compactMap({ $0 }) {
                try fileManager.setAttributes(
                    [
                        .protectionKey: FileProtectionType.complete,
                        .immutable: true
                    ],
                    ofItemAtPath: url.path
                )
            }
            var value = try journal(batchID: asset.batchID)
            value.finalizedAssetIDs.append(asset.id)
            value.finalizedAssetIDs = Array(Set(value.finalizedAssetIDs))
                .sorted { $0.uuidString < $1.uuidString }
            if let index = value.finalizationTransactions.firstIndex(
                where: { $0.assetID == asset.id }
            ) {
                value.finalizationTransactions[index].state = .filesMoved
            }
            value.state = .partiallyFinalized
            value.updatedAt = Date()
            try writeJournal(value)
            return FinalizedCaptureAsset(
                staged: asset,
                recordID: recordID,
                finalRelativePath: destinationPath,
                finalPreviewRelativePath: previewDestinationPath
            )
        } catch {
            if previewMoved, let previewSource, let previewDestination {
                try? fileManager.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: previewDestination.path
                )
                try? fileManager.moveItem(at: previewDestination, to: previewSource)
            }
            if originalMoved {
                try? fileManager.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: destination.path
                )
                try? fileManager.moveItem(at: destination, to: source)
            }
            throw error
        }
    }

    func rollbackFinalization(_ value: FinalizedCaptureAsset) {
        do {
            let finalURL = try resolve(value.finalRelativePath)
            let stagingURL = try resolve(value.staged.originalRelativePath)
            guard fileManager.fileExists(atPath: finalURL.path) else { return }
            try fileManager.setAttributes(
                [.immutable: false],
                ofItemAtPath: finalURL.path
            )
            try fileManager.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try excludeFromBackupAndVerify(stagingURL.deletingLastPathComponent())
            try fileManager.moveItem(at: finalURL, to: stagingURL)
            try excludeFromBackupAndVerify(stagingURL)
            if let finalPreviewPath = value.finalPreviewRelativePath,
               let stagingPreviewPath = value.staged.previewRelativePath {
                let finalPreviewURL = try resolve(finalPreviewPath)
                let stagingPreviewURL = try resolve(stagingPreviewPath)
                if fileManager.fileExists(atPath: finalPreviewURL.path) {
                    try? fileManager.setAttributes(
                        [.immutable: false],
                        ofItemAtPath: finalPreviewURL.path
                    )
                    try fileManager.moveItem(at: finalPreviewURL, to: stagingPreviewURL)
                    try excludeFromBackupAndVerify(stagingPreviewURL)
                }
            }
            var journal = try self.journal(batchID: value.staged.batchID)
            journal.finalizedAssetIDs.removeAll { $0 == value.staged.id }
            journal.finalizationTransactions.removeAll {
                $0.assetID == value.staged.id
            }
            journal.state = .recoverableFailure
            journal.updatedAt = Date()
            try writeJournal(journal)
        } catch {
            AppLog.vault.error("Capture finalization rollback failed")
        }
    }

    func discardStagedAssets(batchID: UUID, assetIDs: Set<UUID>) throws {
        guard !assetIDs.isEmpty else { return }
        var value = try journal(batchID: batchID)
        guard Set(value.finalizedAssetIDs).isDisjoint(with: assetIDs) else {
            throw CaptureVaultError.invalidBatch
        }
        for asset in value.assets where assetIDs.contains(asset.id) {
            let directory = try resolve(asset.originalRelativePath)
                .deletingLastPathComponent()
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        value.assets.removeAll { assetIDs.contains($0.id) }
        value.updatedAt = Date()
        try writeJournal(value)
    }

    /// Removes an uncommitted batch and all of its protected staging files.
    ///
    /// Finalized or committing assets are never deleted through this path.
    func discardBatch(_ batchID: UUID) throws {
        let directory = try batchDirectory(batchID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let value = try journal(batchID: batchID)
        guard value.finalizedAssetIDs.isEmpty,
              value.finalizationTransactions.isEmpty else {
            throw CaptureVaultError.invalidBatch
        }
        try fileManager.removeItem(at: directory)
    }

    func completeBatchIfPossible(_ batchID: UUID) throws {
        var value = try journal(batchID: batchID)
        guard Set(value.finalizedAssetIDs) == Set(value.assets.map(\.id)) else { return }
        guard value.finalizationTransactions.allSatisfy({
            $0.state == .databaseCommitted
        }) else {
            return
        }
        value.state = .completed
        value.updatedAt = Date()
        try writeJournal(value)
        let directory = try batchDirectory(batchID)
        try? fileManager.removeItem(at: directory)
    }

    func markDatabaseCommitted(_ finalizations: [FinalizedCaptureAsset]) throws {
        let byBatch = Dictionary(grouping: finalizations, by: { $0.staged.batchID })
        for (batchID, values) in byBatch {
            var journal = try journal(batchID: batchID)
            let assetIDs = Set(values.map(\.staged.id))
            for index in journal.finalizationTransactions.indices
            where assetIDs.contains(journal.finalizationTransactions[index].assetID) {
                journal.finalizationTransactions[index].state = .databaseCommitted
            }
            journal.updatedAt = Date()
            try writeJournal(journal)
        }
    }

    @MainActor
    func reconcilePendingFinalizations(context: ModelContext) throws {
        let stagingRoot = try resolve("staging")
        guard fileManager.fileExists(atPath: stagingRoot.path) else { return }
        let directories = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories {
            guard let batchID = UUID(uuidString: directory.lastPathComponent) else {
                continue
            }
            var value = try journal(batchID: batchID)
            guard !value.finalizationTransactions.isEmpty else { continue }
            var committedAssetIDs = Set<UUID>()
            for transaction in value.finalizationTransactions {
                let attachmentID = transaction.assetID
                var descriptor = FetchDescriptor<Attachment>(
                    predicate: #Predicate {
                        $0.id == attachmentID
                    }
                )
                descriptor.fetchLimit = 1
                let persisted = try context.fetch(descriptor).first.map {
                    $0.patientId == transaction.patientID
                        && $0.recordId == transaction.recordID
                        && $0.originalRelativePath
                            == transaction.finalOriginalRelativePath
                } ?? false
                if persisted {
                    guard fileManager.fileExists(
                        atPath: try resolve(
                            transaction.finalOriginalRelativePath
                        ).path
                    ) else {
                        throw CaptureVaultError.integrityMismatch
                    }
                    committedAssetIDs.insert(transaction.assetID)
                } else {
                    try rollbackUncommitted(transaction)
                }
            }
            value.finalizedAssetIDs = Array(
                Set(value.finalizedAssetIDs).intersection(committedAssetIDs)
            ).sorted { $0.uuidString < $1.uuidString }
            value.finalizationTransactions = value.finalizationTransactions
                .filter { committedAssetIDs.contains($0.assetID) }
                .map {
                    var transaction = $0
                    transaction.state = .databaseCommitted
                    return transaction
                }
            value.updatedAt = Date()
            try writeJournal(value)
            if Set(value.finalizedAssetIDs) == Set(value.assets.map(\.id)),
               value.finalizationTransactions.allSatisfy({
                   $0.state == .databaseCommitted
               }) {
                try completeBatchIfPossible(batchID)
            }
        }
    }

    private func rollbackUncommitted(
        _ transaction: CaptureFinalizationTransaction
    ) throws {
        try restoreStagedFile(
            stagedRelativePath: transaction.stagedOriginalRelativePath,
            finalRelativePath: transaction.finalOriginalRelativePath,
            required: true
        )
        if let stagedPreview = transaction.stagedPreviewRelativePath,
           let finalPreview = transaction.finalPreviewRelativePath {
            try restoreStagedFile(
                stagedRelativePath: stagedPreview,
                finalRelativePath: finalPreview,
                required: false
            )
        }
    }

    private func restoreStagedFile(
        stagedRelativePath: String,
        finalRelativePath: String,
        required: Bool
    ) throws {
        let staged = try resolve(stagedRelativePath)
        let final = try resolve(finalRelativePath)
        let stagedExists = fileManager.fileExists(atPath: staged.path)
        let finalExists = fileManager.fileExists(atPath: final.path)
        if stagedExists {
            if finalExists {
                try? fileManager.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: final.path
                )
                try fileManager.removeItem(at: final)
            }
            return
        }
        guard finalExists else {
            if required {
                throw CaptureVaultError.sourceMissing
            }
            return
        }
        try fileManager.createDirectory(
            at: staged.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFromBackupAndVerify(staged.deletingLastPathComponent())
        try? fileManager.setAttributes(
            [.immutable: false],
            ofItemAtPath: final.path
        )
        try fileManager.moveItem(at: final, to: staged)
        try excludeFromBackupAndVerify(staged)
    }

    func url(for relativePath: String) throws -> URL {
        try resolve(relativePath)
    }

    /// Finds finalized Vault files that are no longer referenced by SwiftData.
    ///
    /// Staging files and journals are deliberately excluded because their
    /// lifecycle is owned by the batch journal and crash reconciler.
    func orphanFinalizedAttachmentRelativePaths(
        referencedPaths: Set<String>
    ) throws -> [String] {
        let membersURL = try resolve("members")
        guard fileManager.fileExists(atPath: membersURL.path) else {
            return []
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: membersURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let rootPath = rootURL.standardizedFileURL.path + "/"
        var orphans: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  fileURL.standardizedFileURL.path.hasPrefix(rootPath) else {
                continue
            }
            let relativePath = String(
                fileURL.standardizedFileURL.path.dropFirst(rootPath.count)
            )
            if !referencedPaths.contains(relativePath) {
                orphans.append(relativePath)
            }
        }
        return orphans.sorted()
    }

    private func appendToJournal(_ asset: StagedCaptureAsset) throws {
        var value = try journal(batchID: asset.batchID)
        value.assets.append(asset)
        value.assets.sort { $0.createdAt < $1.createdAt }
        value.updatedAt = Date()
        try writeJournal(value)
    }

    private func writeJournal(_ value: CaptureVaultJournal) throws {
        let directory = try batchDirectory(value.batchID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let data = try encoder.encode(value)
        try data.write(
            to: directory.appendingPathComponent("journal.json"),
            options: [.atomic, .completeFileProtection]
        )
        try excludeFromBackupAndVerify(directory)
        try excludeFromBackupAndVerify(
            directory.appendingPathComponent("journal.json")
        )
    }

    private func batchDirectory(_ batchID: UUID) throws -> URL {
        try resolve("staging/\(batchID.uuidString)")
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw CaptureVaultError.invalidRelativePath
        }
        let value = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard value.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else {
            throw CaptureVaultError.invalidRelativePath
        }
        return value
    }

    private func normalizedExtension(_ value: String) throws -> String {
        let normalized = value.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let allowed = Set(["jpg", "jpeg", "png", "heic", "pdf"])
        guard allowed.contains(normalized),
              normalized.range(of: #"^[a-z0-9]{1,10}$"#, options: .regularExpression) != nil else {
            throw CaptureVaultError.unsupportedType
        }
        return normalized
    }

    private func imageOrPDFMetadata(
        at url: URL,
        type: UTType,
        batchID: UUID,
        assetID: UUID
    ) throws -> (width: Int?, height: Int?, pageCount: Int?, previewRelativePath: String?) {
        guard !type.conforms(to: .pdf) else {
            let source = CGPDFDocument(url as CFURL)
            return (nil, nil, source?.numberOfPages, nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            throw CaptureVaultError.invalidImage
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        guard let width, let height, width > 0, height > 0 else {
            throw CaptureVaultError.invalidImage
        }
        guard max(width, height) <= Self.maximumImageDimension else {
            throw CaptureVaultError.imageDimensionsTooLarge
        }
        let preview = try writePreviewIfNeeded(
            source: source,
            batchID: batchID,
            assetID: assetID,
            width: width,
            height: height
        )
        return (width, height, nil, preview)
    }

    private func writePreviewIfNeeded(
        source: CGImageSource,
        batchID: UUID,
        assetID: UUID,
        width: Int?,
        height: Int?
    ) throws -> String? {
        guard let width, let height, width > 0, height > 0 else {
            throw CaptureVaultError.invalidImage
        }
        let target = CaptureImagePreviewPolicy.targetDimensions(
            width: width,
            height: height
        )
        guard target != CapturePreviewDimensions(width: width, height: height) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.workingImageMaximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw CaptureVaultError.invalidImage
        }
        let relativePath = "staging/\(batchID.uuidString)/\(assetID.uuidString)/preview.jpg"
        let url = try resolve(relativePath)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptureVaultError.invalidImage
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [
                kCGImageDestinationLossyCompressionQuality: 0.85
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureVaultError.invalidImage
        }
        try excludeFromBackupAndVerify(url.deletingLastPathComponent())
        try excludeFromBackupAndVerify(url)
        return relativePath
    }

    private func excludeFinalHierarchy(
        patientID: UUID,
        recordID: UUID,
        attachmentID: UUID
    ) throws {
        let paths = [
            "members",
            "members/\(patientID.uuidString)",
            "members/\(patientID.uuidString)/records",
            "members/\(patientID.uuidString)/records/\(recordID.uuidString)",
            "members/\(patientID.uuidString)/records/\(recordID.uuidString)/attachments",
            "members/\(patientID.uuidString)/records/\(recordID.uuidString)/attachments/"
                + attachmentID.uuidString
        ]
        for path in paths {
            let url = try resolve(path)
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try excludeFromBackupAndVerify(url)
        }
    }

    private func excludeFromBackupAndVerify(_ sourceURL: URL) throws {
        var url = sourceURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let verified = try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup
        guard verified == true else {
            throw CaptureVaultError.backupExclusionFailed
        }
    }

    /// The journal's ISO-8601 representation has one-second precision. Keep
    /// the returned asset on that same precision so strict ledger equality
    /// survives an encode/decode round trip.
    private func journalTimestamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    fileprivate func deleteVaultFiles(relativePaths: Set<String>) {
        for relativePath in relativePaths {
            do {
                let url = try resolve(relativePath)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                try? fileManager.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: url.path
                )
                try fileManager.removeItem(at: url)
            } catch {
                AppLog.vault.error(
                    "Vault deletion left a recoverable orphan at \(relativePath, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: streamingChunkBytes) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension CaptureVaultService: AttachmentFileDeleting {
    func deleteAttachmentFiles(
        derivedRelativePaths: Set<String>,
        unreferencedOriginalRelativePaths: Set<String>
    ) {
        deleteVaultFiles(
            relativePaths: derivedRelativePaths
                .union(unreferencedOriginalRelativePaths)
        )
    }
}

extension CaptureVaultService: MemberVaultProvisioning {
    func provisionVault(for patientId: UUID) throws {
        let memberRoot = try resolve("members/\(patientId.uuidString)")
        let recordsRoot = memberRoot.appendingPathComponent(
            "records",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: recordsRoot,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFromBackupAndVerify(memberRoot)
        try excludeFromBackupAndVerify(recordsRoot)
    }

    func rollbackVault(for patientId: UUID) {
        do {
            let memberRoot = try resolve("members/\(patientId.uuidString)")
            guard fileManager.fileExists(atPath: memberRoot.path) else { return }
            try fileManager.removeItem(at: memberRoot)
        } catch {
            AppLog.vault.error("Member Vault rollback left a recoverable orphan")
        }
    }
}
