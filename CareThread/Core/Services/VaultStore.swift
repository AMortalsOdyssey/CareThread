import Foundation
import UniformTypeIdentifiers

enum VaultStoreError: Error, Equatable {
    case unsupportedFileType
    case invalidRelativePath
    case fileMissing
}

struct StoredAttachment: Equatable {
    var workingRelativePath: String
    var originalRelativePath: String
}

final class VaultStore {
    let rootURL: URL
    private let fileManager: FileManager
    private let calendar: Calendar

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        calendar: Calendar = CTDate.calendar
    ) throws {
        self.fileManager = fileManager
        self.calendar = calendar
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootURL = support.appendingPathComponent("Vault", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    func store(
        data: Data,
        fileExtension: String,
        date: Date,
        id: UUID = UUID()
    ) throws -> StoredAttachment {
        let normalized = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard ["jpg", "jpeg", "png", "heic", "pdf"].contains(normalized) else {
            AppLog.vault.warning(
                "Rejected unsupported attachment extension: \(normalized, privacy: .private(mask: .hash))"
            )
            throw VaultStoreError.unsupportedFileType
        }

        let components = calendar.dateComponents([.year, .month], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let base = "attachments/\(year)/\(month)"
        let workingPath = "\(base)/\(id.uuidString).\(normalized)"
        let originalPath = "\(base)/originals/\(id.uuidString).\(normalized)"

        try writeOnce(data, relativePath: workingPath)
        try writeOnce(data, relativePath: originalPath)
        AppLog.vault.info(
            "Stored attachment \(id.uuidString, privacy: .private(mask: .hash))"
        )
        return StoredAttachment(
            workingRelativePath: workingPath,
            originalRelativePath: originalPath
        )
    }

    func data(relativePath: String) throws -> Data {
        let url = try resolvedURL(relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            AppLog.vault.warning(
                "Attachment is missing at \(relativePath, privacy: .private(mask: .hash))"
            )
            throw VaultStoreError.fileMissing
        }
        return try Data(contentsOf: url)
    }

    func delete(relativePaths: [String]) {
        for path in relativePaths {
            do {
                let url = try resolvedURL(path)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                AppLog.vault.error(
                    "Failed to remove attachment \(path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    func orphanRelativePaths(referencedPaths: Set<String>) throws -> [String] {
        let attachmentsURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
        guard fileManager.fileExists(atPath: attachmentsURL.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: attachmentsURL,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }
        var result: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            if !referencedPaths.contains(relative) {
                result.append(relative)
            }
        }
        return result.sorted()
    }

    private func writeOnce(_ data: Data, relativePath: String) throws {
        let url = try resolvedURL(relativePath)
        guard !fileManager.fileExists(atPath: url.path) else {
            AppLog.vault.warning(
                "Immutable attachment already exists at \(relativePath, privacy: .private(mask: .hash))"
            )
            return
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func resolvedURL(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw VaultStoreError.invalidRelativePath
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else {
            throw VaultStoreError.invalidRelativePath
        }
        return url
    }
}

extension VaultStore: AttachmentFileDeleting {
    func deleteAttachmentFiles(
        derivedRelativePaths: Set<String>,
        unreferencedOriginalRelativePaths: Set<String>
    ) {
        delete(
            relativePaths: Array(
                derivedRelativePaths.union(unreferencedOriginalRelativePaths)
            )
        )
    }
}
