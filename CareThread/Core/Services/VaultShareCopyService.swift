import Foundation

enum VaultShareCopyError: Error, Equatable {
    case attachmentScopeMismatch
    case sourceIntegrityMismatch
    case unsafeDisplayName
    case backupExclusionFailed
}

/// Produces a disposable copy for the system share sheet.
///
/// The immutable Vault URL is never handed to another process. Copies live in
/// a protected, backup-excluded temporary directory and are removed by age.
struct VaultShareCopyService {
    static let defaultLifetime: TimeInterval = 24 * 60 * 60

    let vault: CaptureVaultService
    let shareRootURL: URL
    var fileManager: FileManager = .default
    var now: () -> Date = Date.init

    init(
        vault: CaptureVaultService,
        shareRootURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.vault = vault
        self.fileManager = fileManager
        self.shareRootURL = shareRootURL
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "CareThreadShare",
                isDirectory: true
            )
        self.now = now
    }

    func makeCopy(
        for attachment: Attachment,
        patientID: UUID,
        recordID: UUID
    ) throws -> URL {
        guard attachment.patientId == patientID,
              attachment.recordId == recordID,
              attachment.integrityState == .verified else {
            throw VaultShareCopyError.attachmentScopeMismatch
        }
        try prepareShareRoot()
        cleanupExpiredCopies()

        let source = try vault.url(
            for: attachment.originalFileName ?? attachment.fileName
        )
        let sourceValues = try source.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard sourceValues.isRegularFile == true,
              Int64(sourceValues.fileSize ?? -1) == attachment.byteCount,
              try CaptureVaultService.sha256File(at: source) == attachment.sha256
        else {
            throw VaultShareCopyError.sourceIntegrityMismatch
        }

        let displayName = safeDisplayName(
            attachment.displayFileName,
            fallbackExtension: source.pathExtension
        )
        guard !displayName.isEmpty else {
            throw VaultShareCopyError.unsafeDisplayName
        }
        let directory = shareRootURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFromBackup(directory)
        let destination = directory.appendingPathComponent(
            displayName,
            isDirectory: false
        )
        do {
            try fileManager.copyItem(at: source, to: destination)
            // The Vault original is intentionally immutable. `copyItem` also
            // copies that flag on APFS, which prevents adding the backup
            // exclusion extended attribute to the disposable copy.
            try fileManager.setAttributes(
                [
                    .immutable: false,
                    .protectionKey: FileProtectionType.complete
                ],
                ofItemAtPath: destination.path
            )
            try excludeFromBackup(destination)
        } catch {
            try? fileManager.setAttributes(
                [.immutable: false],
                ofItemAtPath: destination.path
            )
            try? fileManager.removeItem(at: directory)
            throw error
        }

        let copiedValues = try destination.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard copiedValues.isRegularFile == true,
              Int64(copiedValues.fileSize ?? -1) == attachment.byteCount,
              try CaptureVaultService.sha256File(at: destination) == attachment.sha256
        else {
            try? fileManager.removeItem(at: directory)
            throw VaultShareCopyError.sourceIntegrityMismatch
        }
        return destination
    }

    func cleanupExpiredCopies(
        lifetime: TimeInterval = Self.defaultLifetime
    ) {
        guard let values = try? fileManager.contentsOfDirectory(
            at: shareRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = now().addingTimeInterval(-max(0, lifetime))
        for url in values {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if modified.map({ $0 < cutoff }) == true {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func prepareShareRoot() throws {
        try fileManager.createDirectory(
            at: shareRootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try excludeFromBackup(shareRootURL)
    }

    private func safeDisplayName(
        _ value: String,
        fallbackExtension: String
    ) -> String {
        let leaf = URL(fileURLWithPath: value).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !leaf.isEmpty, leaf != ".", leaf != ".." {
            return leaf
        }
        let ext = fallbackExtension
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return ext.isEmpty ? "original" : "original.\(ext)"
    }

    private func excludeFromBackup(_ source: URL) throws {
        var value = source
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try value.setResourceValues(resourceValues)
        guard try value.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true else {
            throw VaultShareCopyError.backupExclusionFailed
        }
    }
}
