import Foundation

/// Runs CPU/file-only backup work away from the caller while explicitly
/// propagating structured-task cancellation into the unstructured worker.
func runBackupWorker<Value: Sendable>(
    priority: TaskPriority = .userInitiated,
    operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let worker = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}

enum BackupScope: Codable, Equatable, Sendable {
    case singleMember(UUID)
    case allMembers

    private enum CodingKeys: String, CodingKey {
        case kind
        case memberID
    }

    private enum Kind: String, Codable {
        case singleMember
        case allMembers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .singleMember:
            self = .singleMember(try values.decode(UUID.self, forKey: .memberID))
        case .allMembers:
            self = .allMembers
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .singleMember(id):
            try values.encode(Kind.singleMember, forKey: .kind)
            try values.encode(id, forKey: .memberID)
        case .allMembers:
            try values.encode(Kind.allMembers, forKey: .kind)
        }
    }
}

struct BackupFileEntry: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String
}

struct BackupManifest: Codable, Equatable, Sendable {
    static let formatIdentifier = "io.8xd.carethread.backup"
    static let formatVersion = 1
    static let schemaVersion = "1.0.0"

    let formatIdentifier: String
    let formatVersion: Int
    let schemaVersion: String
    let backupID: UUID
    let exportedAt: Date
    let scope: BackupScope
    let memberNames: [String]
    let entityCounts: [String: Int]
    let files: [BackupFileEntry]

    init(
        backupID: UUID,
        exportedAt: Date,
        scope: BackupScope,
        memberNames: [String],
        entityCounts: [String: Int],
        files: [BackupFileEntry]
    ) {
        formatIdentifier = Self.formatIdentifier
        formatVersion = Self.formatVersion
        schemaVersion = Self.schemaVersion
        self.backupID = backupID
        self.exportedAt = exportedAt
        self.scope = scope
        self.memberNames = memberNames
        self.entityCounts = entityCounts
        self.files = files
    }

    func validate() throws {
        guard formatIdentifier == Self.formatIdentifier,
              formatVersion == Self.formatVersion,
              schemaVersion == Self.schemaVersion,
              !memberNames.isEmpty,
              memberNames.count <= BackupLimits.maximumMembers,
              entityCounts.values.allSatisfy({ $0 >= 0 }),
              files.count <= BackupLimits.maximumEntries else {
            throw BackupError.invalidManifest
        }
        let paths = files.map(\.relativePath)
        guard Set(paths).count == paths.count,
              files.allSatisfy({
                  BackupPathPolicy.isSafeRelativePath($0.relativePath)
                      && $0.byteCount >= 0
                      && $0.byteCount <= BackupLimits.maximumEntryBytes
                      && $0.sha256.range(
                          of: "^[0-9a-f]{64}$",
                          options: .regularExpression
                      ) != nil
              }) else {
            throw BackupError.invalidManifest
        }
        let total = files.reduce(into: Int64(0)) { partial, file in
            partial = min(Int64.max, partial + file.byteCount)
        }
        guard total <= BackupLimits.maximumExpandedBytes else {
            throw BackupError.archiveTooLarge
        }
    }
}

struct BackupPreview: Equatable, Sendable {
    let backupID: UUID
    let exportedAt: Date
    let memberNames: [String]
    let memberCount: Int
    let recordCount: Int
    let attachmentCount: Int
    let totalByteCount: Int64
}

struct BackupExportPackage: Sendable {
    let archiveURL: URL
    let preview: BackupPreview

    /// Removes the complete UUID-scoped export workspace, including readable
    /// intermediate files. A package can be discarded repeatedly.
    func discard(fileManager: FileManager = .default) {
        let container = archiveURL.deletingLastPathComponent()
        guard UUID(uuidString: container.lastPathComponent) != nil else {
            AppLog.vault.error("Refused to discard backup outside UUID workspace")
            return
        }
        do {
            if fileManager.fileExists(atPath: container.path) {
                try fileManager.removeItem(at: container)
            }
        } catch {
            AppLog.vault.error(
                "Failed to discard protected backup workspace: \(error.localizedDescription)"
            )
        }
    }
}

struct BackupImportPlan: Sendable {
    let manifest: BackupManifest
    let preview: BackupPreview
    /// UUID-scoped directory created by preflight. This is deliberately
    /// separate from `stagedRootURL`, which may be nested under content/.
    let stagingContainerURL: URL
    let stagedRootURL: URL
    let portablePayload: BackupPortablePayloadV1

    /// Cancels a preflight that the user chose not to restore. A plan can be
    /// discarded repeatedly and never removes a non-UUID parent directory.
    func discard(fileManager: FileManager = .default) {
        guard UUID(uuidString: stagingContainerURL.lastPathComponent) != nil,
              stagedRootURL.standardizedFileURL.path.hasPrefix(
                  stagingContainerURL.standardizedFileURL.path + "/"
              ) else {
            AppLog.vault.error("Refused to discard backup preflight outside UUID workspace")
            return
        }
        do {
            if fileManager.fileExists(atPath: stagingContainerURL.path) {
                try fileManager.removeItem(at: stagingContainerURL)
            }
        } catch {
            AppLog.vault.error(
                "Failed to discard backup preflight workspace: \(error.localizedDescription)"
            )
        }
    }
}

struct BackupImportResult: Equatable, Sendable {
    let backupID: UUID
    let memberCount: Int
    let recordCount: Int
    let attachmentCount: Int
}

enum BackupError: Error, Equatable, LocalizedError {
    case unsupportedArchive
    case unsafePath
    case symbolicLink
    case duplicateEntry
    case archiveTooLarge
    case suspiciousCompression
    case tooManyEntries
    case invalidManifest
    case manifestCountMismatch
    case integrityMismatch
    case unsupportedSchema
    case memberLimit
    case missingOriginal
    case invalidRelationship
    case insufficientStorage
    case restoreNotConfirmed
    case passwordRequired
    case weakPassword
    case decryptionFailed
    case recoveryFailed
    case injectedFailure

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive:
            "这不是 CareThread 可识别的备份包。"
        case .unsafePath, .symbolicLink, .duplicateEntry:
            "备份包包含不安全的文件路径，已停止恢复。"
        case .archiveTooLarge, .tooManyEntries:
            "备份包超过安全恢复上限。"
        case .suspiciousCompression:
            "备份包压缩比例异常，已停止恢复。"
        case .invalidManifest, .manifestCountMismatch:
            "备份清单与内容不一致，当前资料没有改变。"
        case .integrityMismatch, .missingOriginal:
            "备份中的原件校验失败，当前资料没有改变。"
        case .unsupportedSchema:
            "这份备份来自不兼容的 CareThread 版本。"
        case .memberLimit:
            "备份包含超过 20 位成员，无法恢复。"
        case .invalidRelationship:
            "备份中的资料关系不完整，当前资料没有改变。"
        case .insufficientStorage:
            "可用空间不足，无法安全恢复。"
        case .restoreNotConfirmed:
            "恢复已取消。"
        case .passwordRequired:
            "请输入这份加密备份的口令。"
        case .weakPassword:
            "备份口令至少需要 12 个字符。"
        case .decryptionFailed:
            "口令不正确，或加密备份已经损坏。当前资料没有改变。"
        case .recoveryFailed:
            "自动回滚未完成，请保留本机资料并重新打开应用。"
        case .injectedFailure:
            "测试恢复中断。"
        }
    }
}

enum BackupLimits {
    static let maximumMembers = 20
    static let maximumEntries = 20_000
    static let maximumExpandedBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumEntryBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    static let maximumPortableJSONBytes: Int64 = 128 * 1_024 * 1_024
    static let maximumCompressionRatio: Int64 = 250
    static let minimumFreeSpaceBytes: Int64 = 64 * 1_024 * 1_024

    static func validatePortableJSONByteCount(_ byteCount: Int64) throws {
        guard byteCount >= 0, byteCount <= maximumPortableJSONBytes else {
            throw BackupError.archiveTooLarge
        }
    }
}

enum BackupPathPolicy {
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.isEmpty
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

struct BackupPortablePayloadV1: Codable, Sendable {
    let schemaVersion: Int
    let entities: [NearbySyncEntityPayloadV1]
    let importBatches: [BackupImportBatchDTO]
    let captureDrafts: [BackupCaptureDraftDTO]
    let capturePages: [BackupCapturePageDTO]
    let appleReminderBindings: [BackupAppleReminderBindingDTO]
    let contentRevisions: [BackupContentRevisionDTO]
}

struct BackupImportBatchDTO: Codable, Sendable {
    let id: UUID
    let patientID: UUID
    let sourceType: SourceType
    let stateStatus: ImportBatchStatus
    let generation: Int
    let createdAt: Date
    let updatedAt: Date
}

struct BackupCaptureDraftDTO: Codable, Sendable {
    let id: UUID
    let patientID: UUID
    let batchID: UUID
    let documentIndex: Int
    let groupingRevision: Int
    let generation: Int
    let titleSuggestion: String?
    let confirmedTitle: String?
    let sourceType: SourceType
    let attachmentPaths: [String]
    let selectedType: RecordType?
    let selectedDate: Date?
    let ocrText: String?
    let machineExtraction: ExtractionResult?
    let updatedAt: Date
    let contentRevision: Int
}

struct BackupCapturePageDTO: Codable, Sendable {
    let id: UUID
    let patientID: UUID
    let batchID: UUID
    let draftID: UUID
    let sourceOrder: Int
    let pageIndex: Int
    let stagingRelativePath: String?
    let attachmentID: UUID?
    let ocrGeneration: Int
    let ocrStatus: CaptureOCRStatus
    let ocrText: String?
    let detectedNameCandidates: [DetectedNameCandidate]
    let hospitalSuggestion: String?
    let dateSuggestion: Date?
    let titleSuggestion: String?
    let pageMarker: String?
    let overlapFingerprint: String?
    let confirmedHospital: String?
    let confirmedDate: Date?
    let confirmedTitle: String?
    let createdAt: Date
    let contentRevision: Int
}

struct BackupAppleReminderBindingDTO: Codable, Sendable {
    let id: UUID
    let patientID: UUID
    let reminderID: UUID
    let destination: ReminderDestination
    let localNotificationIdentifier: String?
    let calendarEventIdentifier: String?
    let createdAt: Date
    let updatedAt: Date
}

struct BackupContentRevisionDTO: Codable, Sendable {
    let id: UUID
    let entityKind: EditableEntityKind
    let entityID: UUID
    let patientID: UUID
    let revision: Int
    let changedFieldKeys: [String]
    let beforeContentPayload: Data
    let afterContentPayload: Data
    let source: ContentRevisionSource
    let actor: ContentRevisionActor
    let createdAt: Date
}

struct BackupRecoveryJournal: Codable, Equatable {
    enum State: String, Codable {
        case prepared
        case vaultSwapped
        case databaseCommitted
    }

    let transactionID: UUID
    let snapshotPayloadRelativePath: String
    let oldMembersRelativePath: String
    var state: State
}
