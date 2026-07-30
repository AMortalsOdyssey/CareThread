import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct DatabaseBootstrapperTests {
    @Test("持久库打开失败进入独立内存恢复态且错误脱敏")
    func persistentFailure_usesRecoveryMemoryContainer() throws {
        var modes: [DatabaseStoreMode] = []
        let state = DatabaseBootstrapper.bootstrap { mode in
            modes.append(mode)
            if mode == .persistent {
                throw InjectedDatabaseError.open(
                    "/private/tmp/CareThreadFixture/health.sqlite",
                    "患者王某"
                )
            }
            return try TestSupport.container()
        }

        guard case let .recovery(info, container?) = state else {
            Issue.record("应进入恢复态并提供独立内存容器")
            return
        }
        #expect(modes == [.persistent, .recoveryMemory])
        #expect(!info.userMessage.contains("/private/tmp"))
        #expect(!info.userMessage.contains("王某"))
        #expect(info.referenceCode.hasPrefix("DB-"))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Patient>()) == 0)
    }

    @Test("正常持久库构建直接进入 ready")
    func persistentSuccess_isReady() throws {
        let expected = try TestSupport.container()
        let state = DatabaseBootstrapper.bootstrap { mode in
            #expect(mode == .persistent)
            return expected
        }
        guard case let .ready(actual) = state else {
            Issue.record("应进入 ready")
            return
        }
        #expect(actual === expected)
    }

    @Test("恢复内存容器也失败时仍不 fatal")
    func recoveryBuilderFailure_remainsRecoverableState() {
        let state = DatabaseBootstrapper.bootstrap { _ in
            throw InjectedDatabaseError.open("secret", "private")
        }
        guard case let .recovery(info, container) = state else {
            Issue.record("应保留恢复态")
            return
        }
        #expect(container == nil)
        #expect(!info.userMessage.contains("secret"))
        #expect(!info.userMessage.contains("private"))
    }

    @Test("持久库使用明确受保护目录并重设 SQLite sidecars")
    func persistentBuilder_hardensExplicitStoreAndSidecars() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = RecordingDatabaseStoreFileManager(root: root)

        _ = try DatabaseBootstrapper.defaultBuilder(
            mode: .persistent,
            fileSystem: fileSystem
        )

        let directory = root
            .appendingPathComponent("CareThread", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)
        let store = directory.appendingPathComponent("CareThread.sqlite")
        let expectedProtectedPaths: Set<String> = [
            directory.path,
            store.path,
            store.path + "-wal",
            store.path + "-shm"
        ]
        #expect(fileSystem.createdURLs == [directory])
        #expect(
            expectedProtectedPaths.isSubset(
                of: Set(fileSystem.protectedURLs.map(\.path))
            )
        )
        #expect(
            fileSystem.requestedProtections.allSatisfy {
                $0 == .complete
            }
        )
    }

    @Test("数据库保护元数据设置失败进入恢复态且不删库")
    func protectionFailure_entersRecoveryWithoutDeletingStore() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("existing-marker")
        FileManager.default.createFile(
            atPath: marker.path,
            contents: Data("keep".utf8)
        )
        let failing = FailingDatabaseStoreFileManager(root: root)

        let state = DatabaseBootstrapper.bootstrap { mode in
            if mode == .persistent {
                return try DatabaseBootstrapper.defaultBuilder(
                    mode: mode,
                    fileSystem: failing
                )
            }
            return try TestSupport.container()
        }

        guard case .recovery = state else {
            Issue.record("保护设置失败必须进入恢复态")
            return
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(failing.deleteCallCount == 0)
    }
}

private enum InjectedDatabaseError: Error {
    case open(String, String)
}

private final class RecordingDatabaseStoreFileManager: DatabaseStoreFileManaging {
    let root: URL
    private(set) var createdURLs: [URL] = []
    private(set) var protectedURLs: [URL] = []
    private(set) var requestedProtections: [FileProtectionType] = []

    init(root: URL) {
        self.root = root
    }

    func applicationSupportDirectory() throws -> URL {
        root
    }

    func createDirectory(
        at url: URL,
        protection: FileProtectionType
    ) throws {
        createdURLs.append(url)
        requestedProtections.append(protection)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func itemExists(at url: URL) -> Bool {
        true
    }

    func protectAndExcludeFromBackup(
        _ url: URL,
        protection: FileProtectionType
    ) throws {
        protectedURLs.append(url)
        requestedProtections.append(protection)
    }
}

private final class FailingDatabaseStoreFileManager: DatabaseStoreFileManaging {
    let root: URL
    private(set) var deleteCallCount = 0

    init(root: URL) {
        self.root = root
    }

    func applicationSupportDirectory() throws -> URL {
        root
    }

    func createDirectory(
        at url: URL,
        protection: FileProtectionType
    ) throws {
        throw DatabaseProtectionTestError.denied
    }

    func itemExists(at url: URL) -> Bool {
        false
    }

    func protectAndExcludeFromBackup(
        _ url: URL,
        protection: FileProtectionType
    ) throws {
        throw DatabaseProtectionTestError.denied
    }
}

private enum DatabaseProtectionTestError: Error {
    case denied
}
