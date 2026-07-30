import CryptoKit
import Foundation
import Testing
@testable import CareThread

struct NearbyTransferStagingTests {
    @Test("暂存原文件与 journal 使用锁屏即不可读的 complete 保护")
    func stagingUsesCompleteProtection() async throws {
        let context = try StagingTestContext()
        defer { context.cleanup() }
        _ = try await context.receiver()
        let journalURL = context.stagingRoot
            .appendingPathComponent(
                context.transferID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("journal.json")
        let fileProtection = try FileManager.default.attributesOfItem(
            atPath: context.stagedURL.path
        )[.protectionKey] as? FileProtectionType
        let journalProtection = try FileManager.default.attributesOfItem(
            atPath: journalURL.path
        )[.protectionKey] as? FileProtectionType
        #expect(TransferStagingStore.protectionType == .complete)
        if let fileProtection {
            #expect(fileProtection == .complete)
        }
        if let journalProtection {
            #expect(journalProtection == .complete)
        }
    }

    @Test("checkpoint 与 verified 状态可在重启后从 journal 恢复")
    func journalSurvivesStoreReopen() async throws {
        let context = try StagingTestContext()
        defer { context.cleanup() }
        let receiver = try await context.receiver()
        _ = try await receiver.accept(context.frame)

        let receivingStore = try TransferStagingStore(rootURL: context.stagingRoot)
        #expect(
            await receivingStore.recoveryStatuses()[context.transferID] == .receiving
        )
        try await receiver.finalize()
        let verifiedStore = try TransferStagingStore(rootURL: context.stagingRoot)
        #expect(
            await verifiedStore.recoveryStatuses()[context.transferID] == .verified
        )
    }

    @Test("暂存文件被替换为 symlink 时在写盘前拒绝")
    func stagingSymlinkSwapIsRejected() async throws {
        let context = try StagingTestContext()
        defer { context.cleanup() }
        let receiver = try await context.receiver()
        try FileManager.default.removeItem(at: context.stagedURL)
        try FileManager.default.createSymbolicLink(
            at: context.stagedURL,
            withDestinationURL: context.sourceURL
        )
        await #expect(throws: TransferProtocolError.unsafeStagingPath) {
            _ = try await receiver.accept(context.frame)
        }
        #expect(try Data(contentsOf: context.sourceURL) == context.payload)
    }

    @Test("committing journal 重启后显式标为 interruptedCommit")
    func interruptedCommitIsRecoverable() async throws {
        let context = try StagingTestContext()
        defer { context.cleanup() }
        let receiver = try await context.receiver()
        _ = try await receiver.accept(context.frame)
        try await receiver.finalize()
        try await context.store.markCommitting(transferID: context.transferID)

        let reopened = try TransferStagingStore(rootURL: context.stagingRoot)
        #expect(
            await reopened.recoveryStatuses()[context.transferID] == .interruptedCommit
        )
    }
}

private struct StagingTestContext {
    let root: URL
    let stagingRoot: URL
    let sourceURL: URL
    let stagedURL: URL
    let store: TransferStagingStore
    let payload = Data("fictional-staging-payload".utf8)
    let transferID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    let patientID = UUID(uuidString: "72000000-0000-0000-0000-000000000002")!
    let fileID = UUID(uuidString: "73000000-0000-0000-0000-000000000003")!
    let key = SymmetricKey(data: Data(repeating: 0x73, count: 32))
    let descriptor: ValidatedTransferFileDescriptor
    let frame: EncryptedChunkFrame

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        sourceURL = root.appendingPathComponent("source.bin")
        try payload.write(to: sourceURL)
        stagedURL = stagingRoot
            .appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(fileID.uuidString.lowercased())
            .appendingPathExtension("partial")
        let raw = TransferFileDescriptor(
            kind: .originalAttachment,
            fileID: fileID,
            patientID: patientID,
            ownerAttachmentID: UUID(
                uuidString: "74000000-0000-0000-0000-000000000004"
            )!,
            relativePath: "members/\(patientID.uuidString.lowercased())/source.bin",
            byteCount: Int64(payload.count),
            sha256: Data(SHA256.hash(data: payload)).testHex
        )
        descriptor = try raw.validated()
        frame = try TransferChunkCrypto.seal(
            plaintext: payload,
            header: TransferChunkHeader(
                transferID: transferID,
                fileID: fileID,
                sequence: 0,
                offset: 0,
                plaintextCount: payload.count,
                isFinal: true
            ),
            using: key
        )
        store = try TransferStagingStore(rootURL: stagingRoot)
    }

    func receiver() async throws -> TransferFileChunkReceiver {
        try await TransferFileChunkReceiver.make(
            stagingStore: store,
            descriptor: descriptor,
            transferID: transferID,
            key: key
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
