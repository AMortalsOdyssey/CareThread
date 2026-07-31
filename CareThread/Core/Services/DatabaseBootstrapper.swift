import Foundation
import SwiftData

protocol DatabaseStoreFileManaging {
    func applicationSupportDirectory() throws -> URL
    func createDirectory(
        at url: URL,
        protection: FileProtectionType
    ) throws
    func itemExists(at url: URL) -> Bool
    func protectAndExcludeFromBackup(
        _ url: URL,
        protection: FileProtectionType
    ) throws
}

struct FoundationDatabaseStoreFileManager: DatabaseStoreFileManaging {
    private let fileManager: FileManager
    private let applicationSupportOverride: URL?

    init(
        fileManager: FileManager = .default,
        applicationSupportOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.applicationSupportOverride = applicationSupportOverride
    }

    func applicationSupportDirectory() throws -> URL {
        if let applicationSupportOverride {
            return applicationSupportOverride
        }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    func createDirectory(
        at url: URL,
        protection: FileProtectionType
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        try fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func protectAndExcludeFromBackup(
        _ url: URL,
        protection: FileProtectionType
    ) throws {
        try fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}

enum DatabaseStoreMode: Equatable {
    case persistent
    case recoveryMemory
}

struct DatabaseRecoveryInfo: Equatable {
    let referenceCode: String
    let userMessage: String
}

enum DatabaseBootstrapState {
    case ready(ModelContainer)
    case recovery(info: DatabaseRecoveryInfo, container: ModelContainer?)
}

@MainActor
enum DatabaseBootstrapper {
    typealias ContainerBuilder = @MainActor (DatabaseStoreMode) throws -> ModelContainer
    static let protection: FileProtectionType = .complete
    static let applicationSupportSubdirectory = "CareThread"
    static let databaseDirectoryName = "Database"
    static let storeFileName = "CareThread.sqlite"

    static func bootstrap(
        builder: @escaping ContainerBuilder = defaultBuilder
    ) -> DatabaseBootstrapState {
        do {
            return .ready(try builder(.persistent))
        } catch {
            let info = recoveryInfo(for: error)
            AppLog.data.error("Persistent database open failed; entered protected recovery")
            // This container is intentionally independent. It never points at,
            // deletes, moves, or rebuilds the failed persistent store.
            let recoveryContainer = try? builder(.recoveryMemory)
            return .recovery(info: info, container: recoveryContainer)
        }
    }

    /// UI automation must never fall back to the user's persistent store.
    ///
    /// A failed in-memory container is surfaced as a protected recovery state
    /// instead of silently invoking `.persistent`, which prevents test records
    /// from leaking into an installed app or TestFlight-style build.
    static func bootstrapIsolatedUITest(
        builder: @escaping ContainerBuilder = defaultBuilder
    ) -> DatabaseBootstrapState {
        do {
            return .ready(try builder(.recoveryMemory))
        } catch {
            AppLog.data.error(
                "UI test in-memory database open failed; persistent fallback blocked"
            )
            return .recovery(
                info: DatabaseRecoveryInfo(
                    referenceCode: "UITEST-DB-0001",
                    userMessage: "UI 自动化的独立资料库无法打开；未读取或写入正式资料库。"
                ),
                container: nil
            )
        }
    }

    static func defaultBuilder(mode: DatabaseStoreMode) throws -> ModelContainer {
        try defaultBuilder(
            mode: mode,
            fileSystem: FoundationDatabaseStoreFileManager()
        )
    }

    static func defaultBuilder(
        mode: DatabaseStoreMode,
        fileSystem: any DatabaseStoreFileManaging
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CareThreadSchemaV1.self)
        if mode == .recoveryMemory {
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: schema,
                migrationPlan: CareThreadMigrationPlan.self,
                configurations: [configuration]
            )
        }

        let applicationSupport = try fileSystem.applicationSupportDirectory()
        let databaseDirectory = applicationSupport
            .appendingPathComponent(
                applicationSupportSubdirectory,
                isDirectory: true
            )
            .appendingPathComponent(databaseDirectoryName, isDirectory: true)
        try fileSystem.createDirectory(
            at: databaseDirectory,
            protection: protection
        )
        try fileSystem.protectAndExcludeFromBackup(
            databaseDirectory,
            protection: protection
        )
        let storeURL = databaseDirectory.appendingPathComponent(storeFileName)
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: CareThreadMigrationPlan.self,
            configurations: [configuration]
        )
        try rehardenStoreArtifacts(
            storeURL: storeURL,
            databaseDirectory: databaseDirectory,
            fileSystem: fileSystem
        )
        return container
    }

    private static func rehardenStoreArtifacts(
        storeURL: URL,
        databaseDirectory: URL,
        fileSystem: any DatabaseStoreFileManaging
    ) throws {
        let sidecars = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        try fileSystem.protectAndExcludeFromBackup(
            databaseDirectory,
            protection: protection
        )
        for url in sidecars where fileSystem.itemExists(at: url) {
            try fileSystem.protectAndExcludeFromBackup(
                url,
                protection: protection
            )
        }
    }

    private static func recoveryInfo(for error: Error) -> DatabaseRecoveryInfo {
        let nsError = error as NSError
        let boundedCode = abs(nsError.code % 10_000)
        return DatabaseRecoveryInfo(
            referenceCode: String(format: "DB-%04d", boundedCode),
            userMessage: "本地资料库暂时无法安全打开。CareThread 没有删除或重建任何资料，请稍后重试或导出诊断编号联系支持。"
        )
    }
}
