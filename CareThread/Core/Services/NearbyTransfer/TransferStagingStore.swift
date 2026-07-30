import Foundation

struct StagedTransferFile: Sendable {
    let storeID: UUID
    let transferID: UUID
    let descriptor: ValidatedTransferFileDescriptor
    let url: URL

    fileprivate init(
        storeID: UUID,
        transferID: UUID,
        descriptor: ValidatedTransferFileDescriptor,
        url: URL
    ) {
        self.storeID = storeID
        self.transferID = transferID
        self.descriptor = descriptor
        self.url = url
    }
}

private struct TransferStagingJournal: Codable {
    enum Status: String, Codable {
        case receiving
        case verified
        case committing
        case committed
    }

    struct Entry: Codable {
        let fileID: UUID
        let byteCount: Int64
        var resume: TransferResumeState
        var verified: Bool
    }

    let transferID: UUID
    var status: Status
    var entries: [String: Entry]
    var updatedAtUTC: Date
    var committedResultSHA256: String?
    var committedReceipt: TransferCommitReceipt?
}

/// Owns the only paths accepted by the receive and commit pipeline. Remote
/// relative paths are never resolved on the receiver.
actor TransferStagingStore {
    nonisolated static let protectionType = FileProtectionType.complete
    private let fileManager: FileManager
    private let rootURL: URL
    private let quotaBytes: Int64
    private let minimumFreeSpaceBytes: Int64
    private let storeID = UUID()
    private var journals: [UUID: TransferStagingJournal] = [:]

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        quotaBytes: Int64 = TransferLimits.maximumStagingBytes,
        minimumFreeSpaceBytes: Int64 = TransferLimits.minimumFreeSpaceBytes
    ) throws {
        guard rootURL.isFileURL else {
            throw TransferProtocolError.unsafeStagingPath
        }
        guard quotaBytes > 0,
              quotaBytes <= TransferLimits.maximumTransferBytes,
              minimumFreeSpaceBytes >= 0 else {
            throw TransferProtocolError.invalidManifest("staging quota")
        }
        self.fileManager = fileManager
        self.rootURL = rootURL.standardizedFileURL
        self.quotaBytes = quotaBytes
        self.minimumFreeSpaceBytes = minimumFreeSpaceBytes
        try Self.createSecureDirectory(self.rootURL, fileManager: fileManager)
        try Self.rejectSymlink(self.rootURL)
        try Self.applyProtection(to: self.rootURL, fileManager: fileManager)
        journals = try Self.loadJournals(from: self.rootURL, fileManager: fileManager)
    }

    func prepare(
        transferID: UUID,
        descriptor: ValidatedTransferFileDescriptor,
        resume: TransferResumeState?
    ) throws -> StagedTransferFile {
        let transferDirectory = rootURL
            .appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
        try Self.assertDescendant(transferDirectory, of: rootURL)
        try Self.createSecureDirectory(transferDirectory, fileManager: fileManager)
        try Self.rejectSymlink(transferDirectory)
        try Self.applyProtection(to: transferDirectory, fileManager: fileManager)

        let filesDirectory = transferDirectory.appendingPathComponent("files", isDirectory: true)
        try Self.createSecureDirectory(filesDirectory, fileManager: fileManager)
        try Self.rejectSymlink(filesDirectory)
        try Self.applyProtection(to: filesDirectory, fileManager: fileManager)

        let url = filesDirectory
            .appendingPathComponent(descriptor.fileID.uuidString.lowercased())
            .appendingPathExtension("partial")
        try Self.assertDescendant(url, of: rootURL)
        if fileManager.fileExists(atPath: url.path) {
            try Self.rejectSymlink(url)
        }
        let existingEntry = journals[transferID]?
            .entries[descriptor.fileID.uuidString.lowercased()]
        if let existingEntry, existingEntry.byteCount != descriptor.byteCount {
            throw TransferProtocolError.invalidManifest("staging descriptor changed")
        }
        let additionalBytes = existingEntry == nil ? descriptor.byteCount : 0
        try ensureCapacity(additionalBytes: additionalBytes)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: Data()) else {
                throw TransferProtocolError.transport("cannot create staging file")
            }
            try Self.applyProtection(to: url, fileManager: fileManager)
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let state: TransferResumeState
        if let resume {
            try resume.validate(for: descriptor, transferID: transferID)
            let size = try handle.seekToEnd()
            guard size >= UInt64(resume.nextOffset) else {
                throw TransferProtocolError.invalidChunk("staging shorter than checkpoint")
            }
            try handle.truncate(atOffset: UInt64(resume.nextOffset))
            state = resume
        } else {
            try handle.truncate(atOffset: 0)
            state = TransferResumeState(transferID: transferID, descriptor: descriptor)
        }
        try handle.synchronize()

        var journal = journals[transferID] ?? TransferStagingJournal(
            transferID: transferID,
            status: .receiving,
            entries: [:],
            updatedAtUTC: Date(),
            committedResultSHA256: nil,
            committedReceipt: nil
        )
        guard journal.status == .receiving || journal.status == .verified else {
            throw TransferProtocolError.invalidStateTransition
        }
        journal.entries[descriptor.fileID.uuidString.lowercased()] = .init(
            fileID: descriptor.fileID,
            byteCount: descriptor.byteCount,
            resume: state,
            verified: false
        )
        journal.status = .receiving
        journal.updatedAtUTC = Date()
        journals[transferID] = journal
        try persist(journal)
        return StagedTransferFile(
            storeID: storeID,
            transferID: transferID,
            descriptor: descriptor,
            url: url
        )
    }

    func openForUpdate(_ staged: StagedTransferFile) throws -> FileHandle {
        try assertCapability(staged)
        return try FileHandle(forUpdating: staged.url)
    }

    func checkpoint(_ staged: StagedTransferFile, resume: TransferResumeState) throws {
        try assertCapability(staged)
        try resume.validate(for: staged.descriptor, transferID: staged.transferID)
        guard var journal = journals[staged.transferID],
              var entry = journal.entries[staged.descriptor.fileID.uuidString.lowercased()],
              !entry.verified else {
            throw TransferProtocolError.invalidStateTransition
        }
        entry.resume = resume
        journal.entries[staged.descriptor.fileID.uuidString.lowercased()] = entry
        journal.updatedAtUTC = Date()
        journals[staged.transferID] = journal
        try persist(journal)
    }

    func markVerified(_ staged: StagedTransferFile) throws {
        try assertCapability(staged)
        guard var journal = journals[staged.transferID],
              var entry = journal.entries[staged.descriptor.fileID.uuidString.lowercased()],
              entry.resume.nextOffset == staged.descriptor.byteCount else {
            throw TransferProtocolError.invalidStateTransition
        }
        entry.verified = true
        journal.entries[staged.descriptor.fileID.uuidString.lowercased()] = entry
        journal.status = journal.entries.values.allSatisfy(\.verified) ? .verified : .receiving
        journal.updatedAtUTC = Date()
        journals[staged.transferID] = journal
        try persist(journal)
    }

    func assertStillSafe(_ staged: StagedTransferFile) throws {
        try assertCapability(staged)
    }

    func hash(_ staged: StagedTransferFile) throws -> String {
        try assertCapability(staged)
        return try TransferFileHashing.sha256(url: staged.url)
    }

    func verifiedFileURL(
        transferID: UUID,
        descriptor: ValidatedTransferFileDescriptor
    ) throws -> URL {
        guard let journal = journals[transferID],
              let entry = journal.entries[descriptor.fileID.uuidString.lowercased()],
              entry.verified else {
            throw TransferProtocolError.missingFile(descriptor.fileID)
        }
        let staged = try capability(transferID: transferID, descriptor: descriptor)
        try assertCapability(staged)
        return staged.url
    }

    func markCommitting(transferID: UUID) throws {
        guard var journal = journals[transferID],
              journal.entries.values.allSatisfy(\.verified) else {
            throw TransferProtocolError.invalidStateTransition
        }
        if journal.status == .committing {
            return
        }
        guard journal.status == .verified else {
            throw TransferProtocolError.invalidStateTransition
        }
        journal.status = .committing
        journal.updatedAtUTC = Date()
        journals[transferID] = journal
        try persist(journal)
    }

    func markCommitted(
        transferID: UUID,
        resultSHA256: String,
        receipt: TransferCommitReceipt
    ) throws {
        guard var journal = journals[transferID],
              journal.status == .committing,
              receipt.transferID == transferID,
              receipt.resultSHA256 == resultSHA256,
              resultSHA256.count == 64 else {
            throw TransferProtocolError.invalidStateTransition
        }
        journal.status = .committed
        journal.committedResultSHA256 = resultSHA256
        journal.committedReceipt = receipt
        journal.updatedAtUTC = Date()
        journals[transferID] = journal
        try persist(journal)
    }

    func committedReceipt(transferID: UUID) -> TransferCommitReceipt? {
        guard let journal = journals[transferID],
              journal.status == .committed,
              journal.committedResultSHA256 == journal.committedReceipt?.resultSHA256 else {
            return nil
        }
        return journal.committedReceipt
    }

    /// Returns only a checkpoint that is still cryptographically bound to the
    /// same validated descriptor. It never exposes a receiver filesystem path.
    func resumeState(
        transferID: UUID,
        descriptor: ValidatedTransferFileDescriptor
    ) throws -> TransferResumeState? {
        guard let journal = journals[transferID],
              let entry = journal.entries[descriptor.fileID.uuidString.lowercased()]
        else {
            return nil
        }
        guard entry.byteCount == descriptor.byteCount else {
            throw TransferProtocolError.invalidManifest("staging descriptor changed")
        }
        try entry.resume.validate(for: descriptor, transferID: transferID)
        return entry.resume
    }

    func refreshCommittedReceipt(
        transferID: UUID,
        receipt: TransferCommitReceipt
    ) throws {
        guard var journal = journals[transferID],
              journal.status == .committed,
              receipt.transferID == transferID,
              receipt.resultSHA256 == journal.committedResultSHA256,
              receipt.manifestSHA256 == journal.committedReceipt?.manifestSHA256 else {
            throw TransferProtocolError.invalidCommitReceipt
        }
        journal.committedReceipt = receipt
        journal.updatedAtUTC = Date()
        journals[transferID] = journal
        try persist(journal)
    }

    func recoveryStatuses() -> [UUID: TransferStagingRecoveryStatus] {
        Dictionary(uniqueKeysWithValues: journals.map { transferID, journal in
            let status: TransferStagingRecoveryStatus
            switch journal.status {
            case .receiving:
                status = .receiving
            case .verified:
                status = .verified
            case .committing:
                status = .interruptedCommit
            case .committed:
                status = .committed
            }
            return (transferID, status)
        })
    }

    /// User cancellation or successful handoff can reclaim a single transfer
    /// without ever resolving a path supplied by the peer.
    func cleanup(transferID: UUID) throws {
        let directory = rootURL.appendingPathComponent(
            transferID.uuidString.lowercased(),
            isDirectory: true
        )
        try Self.assertDescendant(directory, of: rootURL)
        if fileManager.fileExists(atPath: directory.path) {
            try Self.rejectSymlink(directory)
            try fileManager.removeItem(at: directory)
        }
        journals[transferID] = nil
    }

    /// Removes only non-committing journals older than the caller's retention
    /// date. Interrupted commits require explicit importer recovery.
    func cleanupExpired(olderThan cutoff: Date) throws -> [UUID] {
        let expired = journals.compactMap { transferID, journal -> UUID? in
            guard journal.updatedAtUTC < cutoff,
                  journal.status == .receiving
                      || journal.status == .verified
                      || journal.status == .committed else {
                return nil
            }
            return transferID
        }
        for transferID in expired {
            try cleanup(transferID: transferID)
        }
        return expired
    }

    private func capability(
        transferID: UUID,
        descriptor: ValidatedTransferFileDescriptor
    ) throws -> StagedTransferFile {
        let url = rootURL
            .appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(descriptor.fileID.uuidString.lowercased())
            .appendingPathExtension("partial")
        return StagedTransferFile(
            storeID: storeID,
            transferID: transferID,
            descriptor: descriptor,
            url: url
        )
    }

    private func assertCapability(_ staged: StagedTransferFile) throws {
        guard staged.storeID == storeID else {
            throw TransferProtocolError.unsafeStagingPath
        }
        let expected = try capability(
            transferID: staged.transferID,
            descriptor: staged.descriptor
        ).url.standardizedFileURL
        guard staged.url.standardizedFileURL == expected else {
            throw TransferProtocolError.unsafeStagingPath
        }
        try Self.assertDescendant(expected, of: rootURL)
        try Self.rejectSymlink(expected.deletingLastPathComponent())
        try Self.rejectSymlink(expected)
        let values = try expected.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TransferProtocolError.unsafeStagingPath
        }
    }

    private func ensureCapacity(additionalBytes: Int64) throws {
        guard additionalBytes >= 0 else {
            throw TransferProtocolError.invalidManifest("staging size")
        }
        let current = journals.values.reduce(into: Int64(0)) { total, journal in
            for entry in journal.entries.values {
                let (next, overflow) = total.addingReportingOverflow(entry.byteCount)
                total = overflow ? Int64.max : next
            }
        }
        let (projected, overflow) = current.addingReportingOverflow(additionalBytes)
        guard !overflow, projected <= quotaBytes else {
            throw TransferProtocolError.limitExceeded("staging quota")
        }
        let values = try rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let available = values.volumeAvailableCapacityForImportantUsage {
            let (required, requiredOverflow) = additionalBytes.addingReportingOverflow(
                minimumFreeSpaceBytes
            )
            guard !requiredOverflow, available >= required else {
                throw TransferProtocolError.insufficientStorage
            }
        }
    }

    private func persist(_ journal: TransferStagingJournal) throws {
        let directory = rootURL
            .appendingPathComponent(journal.transferID.uuidString.lowercased(), isDirectory: true)
        let url = directory.appendingPathComponent("journal.json")
        let data = try StableJSON.encode(journal)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try Self.applyProtection(to: url, fileManager: fileManager)
    }

    private static func createSecureDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protectionType]
        )
    }

    private static func applyProtection(to url: URL, fileManager: FileManager) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try fileManager.setAttributes(
            [.protectionKey: protectionType],
            ofItemAtPath: url.path
        )
    }

    private static func directoryByteCount(
        _ root: URL,
        fileManager: FileManager,
        stopAfter limit: Int64
    ) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= TransferLimits.maximumFiles * 3 else {
                throw TransferProtocolError.limitExceeded("staging entries")
            }
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey
                ]
            )
            guard values.isSymbolicLink != true else {
                throw TransferProtocolError.unsafeStagingPath
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow, next <= limit else {
                throw TransferProtocolError.limitExceeded("staging quota")
            }
            total = next
        }
        return total
    }

    private static func rejectSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw TransferProtocolError.unsafeStagingPath
        }
    }

    private static func assertDescendant(_ child: URL, of root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else {
            throw TransferProtocolError.unsafeStagingPath
        }
    }

    private static func loadJournals(
        from root: URL,
        fileManager: FileManager
    ) throws -> [UUID: TransferStagingJournal] {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard children.count <= TransferLimits.maximumFiles else {
            throw TransferProtocolError.limitExceeded("staging journal directories")
        }
        var loaded: [UUID: TransferStagingJournal] = [:]
        for child in children {
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw TransferProtocolError.unsafeStagingPath
            }
            guard values.isDirectory == true,
                  let transferID = UUID(uuidString: child.lastPathComponent) else {
                continue
            }
            let journalURL = child.appendingPathComponent("journal.json")
            guard fileManager.fileExists(atPath: journalURL.path) else { continue }
            try rejectSymlink(journalURL)
            let size = try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard size >= 0, size <= TransferLimits.maximumManifestBytes else {
                throw TransferProtocolError.limitExceeded("staging journal bytes")
            }
            let journal: TransferStagingJournal
            do {
                journal = try StableJSON.decode(
                    TransferStagingJournal.self,
                    from: Data(contentsOf: journalURL)
                )
            } catch {
                throw TransferProtocolError.invalidChunk("corrupt staging journal")
            }
            guard journal.transferID == transferID,
                  journal.entries.count <= TransferLimits.maximumFiles,
                  journal.entries.allSatisfy({ key, entry in
                      key == entry.fileID.uuidString.lowercased()
                          && entry.resume.transferID == transferID
                          && entry.byteCount >= 0
                          && entry.byteCount <= TransferLimits.maximumFileBytes
                          && entry.resume.receivedBitmap.count
                              <= TransferLimits.maximumResumeBitmapBytes
                  }),
                  isValidCommittedMaterial(journal) else {
                throw TransferProtocolError.invalidChunk("invalid staging journal")
            }
            loaded[transferID] = journal
        }
        return loaded
    }

    private static func isValidCommittedMaterial(
        _ journal: TransferStagingJournal
    ) -> Bool {
        guard journal.status == .committed else {
            return journal.committedResultSHA256 == nil
                && journal.committedReceipt == nil
        }
        guard let result = journal.committedResultSHA256,
              let receipt = journal.committedReceipt,
              receipt.transferID == journal.transferID,
              receipt.resultSHA256 == result,
              ISO8601DateFormatter().date(from: receipt.committedAtUTC) != nil else {
            return false
        }
        return [result, receipt.manifestSHA256].allSatisfy { value in
            value.count == 64 && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
        }
    }
}

enum TransferStagingRecoveryStatus: Equatable, Sendable {
    case receiving
    case verified
    case interruptedCommit
    case committed
}
