import Foundation
import Testing
@testable import CareThread

struct VaultStoreTests {
    @Test("附件按年月写入工作图和原件目录")
    func test_store_whenValidData_writesWorkingAndOriginal() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        let id = UUID(uuidString: "4B76B8E5-08C0-41F1-A342-0A24383E3F1B")!

        let result = try store.store(
            data: Data("fixture".utf8),
            fileExtension: "JPG",
            date: CTDate.make(2026, 3, 15),
            id: id
        )

        #expect(result.workingRelativePath == "attachments/2026/03/\(id.uuidString).jpg")
        #expect(result.originalRelativePath == "attachments/2026/03/originals/\(id.uuidString).jpg")
        #expect(try store.data(relativePath: result.workingRelativePath) == Data("fixture".utf8))
        #expect(try store.data(relativePath: result.originalRelativePath) == Data("fixture".utf8))
    }

    @Test("重复写同一原件不会覆盖既有字节")
    func test_store_whenSameIdentifierUsed_keepsImmutableBytes() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        let id = UUID()
        let first = try store.store(
            data: Data("first".utf8),
            fileExtension: "png",
            date: CTDate.make(2026, 1, 2),
            id: id
        )
        _ = try store.store(
            data: Data("second".utf8),
            fileExtension: "png",
            date: CTDate.make(2026, 1, 2),
            id: id
        )
        #expect(try store.data(relativePath: first.workingRelativePath) == Data("first".utf8))
        #expect(try store.data(relativePath: first.originalRelativePath) == Data("first".utf8))
    }

    @Test("不支持的扩展名直接拒绝")
    func test_store_whenUnsupportedExtension_throws() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        #expect(throws: VaultStoreError.unsupportedFileType) {
            try store.store(
                data: Data(),
                fileExtension: "exe",
                date: CTDate.make(2026, 1, 1)
            )
        }
    }

    @Test("绝对路径读取被拒绝")
    func test_data_whenAbsolutePath_throws() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        #expect(throws: VaultStoreError.invalidRelativePath) {
            try store.data(relativePath: "/tmp/private")
        }
    }

    @Test("父目录穿越读取被拒绝")
    func test_data_whenPathTraversal_throws() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        #expect(throws: VaultStoreError.invalidRelativePath) {
            try store.data(relativePath: "attachments/../../secret")
        }
    }

    @Test("附件文件丢失时返回明确错误")
    func test_data_whenFileMissing_throwsMissing() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        #expect(throws: VaultStoreError.fileMissing) {
            try store.data(relativePath: "attachments/2026/01/missing.jpg")
        }
    }

    @Test("删除同时移除工作图与原件")
    func test_delete_whenBothPathsProvided_removesFiles() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        let result = try store.store(
            data: Data("fixture".utf8),
            fileExtension: "pdf",
            date: CTDate.make(2025, 12, 1)
        )
        store.delete(relativePaths: [result.workingRelativePath, result.originalRelativePath])
        #expect(throws: VaultStoreError.fileMissing) {
            try store.data(relativePath: result.workingRelativePath)
        }
        #expect(throws: VaultStoreError.fileMissing) {
            try store.data(relativePath: result.originalRelativePath)
        }
    }

    @Test("孤儿扫描只返回未被引用的文件")
    func test_orphans_whenMixedReferences_returnsOnlyUnreferenced() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        let one = try store.store(
            data: Data("one".utf8),
            fileExtension: "jpg",
            date: CTDate.make(2026, 1, 1)
        )
        let two = try store.store(
            data: Data("two".utf8),
            fileExtension: "jpg",
            date: CTDate.make(2026, 1, 1)
        )
        let referenced = Set([one.workingRelativePath, one.originalRelativePath])
        let orphans = try store.orphanRelativePaths(referencedPaths: referenced)
        #expect(orphans == [two.workingRelativePath, two.originalRelativePath].sorted())
    }

    @Test("空 Vault 的孤儿扫描返回空数组")
    func test_orphans_whenVaultEmpty_returnsEmpty() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root)
        #expect(try store.orphanRelativePaths(referencedPaths: []) == [])
    }
}

