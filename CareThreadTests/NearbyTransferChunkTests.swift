import CryptoKit
import Foundation
import Testing
@testable import CareThread

struct NearbyTransferChunkTests {
    @Test("64KiB 固定分块可流式接收并校验最终文件")
    func chunkRoundTripFinalizes() async throws {
        let context = try ChunkTestContext(data: patternedData(count: 150_000))
        defer { context.cleanup() }
        let frames = try await context.frames()
        #expect(frames.count == 3)
        #expect(frames[0].header.plaintextCount == TransferLimits.chunkSize)
        #expect(frames.last?.header.isFinal == true)

        let receiver = try await context.receiver()
        for frame in frames {
            _ = try await receiver.accept(frame)
        }
        try await receiver.finalize()
        #expect(try Data(contentsOf: context.stagingURL) == context.data)
    }

    @Test("满 64KiB wire frame 二进制定长且往返一致")
    func maximumWireFrameRoundTrips() throws {
        let context = try ChunkTestContext(data: patternedData(count: TransferLimits.chunkSize))
        defer { context.cleanup() }
        let header = TransferChunkHeader(
            transferID: context.transferID,
            fileID: context.fileID,
            sequence: 0x0102030405060708,
            offset: 0,
            plaintextCount: TransferLimits.chunkSize,
            isFinal: true
        )
        let frame = try TransferChunkCrypto.seal(
            plaintext: context.data,
            header: header,
            using: context.key
        )
        let wire = try TransferChunkWireCodec.encode(frame)
        #expect(wire.count == TransferChunkWireCodec.maximumEncodedBytes)
        #expect(try TransferChunkWireCodec.decode(wire) == frame)
        #expect(Array(wire[40..<48]) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("wire 声称的 ciphertext 长度与实际不符即拒绝")
    func truncatedWireFrameIsRejected() throws {
        let context = try ChunkTestContext(data: Data("fictional".utf8))
        defer { context.cleanup() }
        let frame = try TransferChunkCrypto.seal(
            plaintext: context.data,
            header: TransferChunkHeader(
                transferID: context.transferID,
                fileID: context.fileID,
                sequence: 0,
                offset: 0,
                plaintextCount: context.data.count,
                isFinal: true
            ),
            using: context.key
        )
        var wire = try TransferChunkWireCodec.encode(frame)
        wire.removeLast()
        #expect(throws: TransferProtocolError.self) {
            try TransferChunkWireCodec.decode(wire)
        }
    }

    @Test("乱序数据块在写盘前被拒绝")
    func outOfOrderChunkIsRejected() async throws {
        let context = try ChunkTestContext(data: patternedData(count: 140_000))
        defer { context.cleanup() }
        let frames = try await context.frames()
        let receiver = try await context.receiver()
        await #expect(throws: TransferProtocolError.outOfOrder(expected: 0, received: 1)) {
            _ = try await receiver.accept(frames[1])
        }
        #expect((try? Data(contentsOf: context.stagingURL).count) == 0)
    }

    @Test("相同重复块幂等，不推进 offset")
    func identicalDuplicateIsIdempotent() async throws {
        let context = try ChunkTestContext(data: patternedData(count: 80_000))
        defer { context.cleanup() }
        let frames = try await context.frames()
        let receiver = try await context.receiver()
        let first = try await receiver.accept(frames[0])
        let duplicate = try await receiver.accept(frames[0])
        #expect(first == .accepted(nextOffset: Int64(TransferLimits.chunkSize)))
        #expect(duplicate == .duplicate(nextOffset: Int64(TransferLimits.chunkSize)))
    }

    @Test("同 sequence 不同明文是冲突而非幂等")
    func conflictingDuplicateIsRejected() async throws {
        let context = try ChunkTestContext(data: patternedData(count: 80_000))
        defer { context.cleanup() }
        let frames = try await context.frames()
        let receiver = try await context.receiver()
        _ = try await receiver.accept(frames[0])
        let conflicting = try TransferChunkCrypto.seal(
            plaintext: Data(repeating: 0xEE, count: TransferLimits.chunkSize),
            header: frames[0].header,
            using: context.key
        )
        await #expect(throws: TransferProtocolError.conflictingDuplicate(sequence: 0)) {
            _ = try await receiver.accept(conflicting)
        }
    }

    @Test("断点位图和 nextOffset 可恢复后续分块")
    func resumeContinuesAtNextOffset() async throws {
        let context = try ChunkTestContext(data: patternedData(count: 170_000))
        defer { context.cleanup() }
        let frames = try await context.frames()
        var firstReceiver: TransferFileChunkReceiver? = try await context.receiver()
        _ = try await firstReceiver?.accept(frames[0])
        let resume = try #require(await firstReceiver?.resumeState())
        #expect(resume.contains(sequence: 0))
        firstReceiver = nil

        let resumed = try await context.receiver(resumeFrom: resume)
        for frame in frames.dropFirst() {
            _ = try await resumed.accept(frame)
        }
        try await resumed.finalize()
        #expect(try Data(contentsOf: context.stagingURL) == context.data)
    }

    @Test("错误会话密钥无法解密且不会推进 journal")
    func wrongChunkKeyIsRejected() async throws {
        let context = try ChunkTestContext(data: Data("fictional".utf8))
        defer { context.cleanup() }
        let frame = try #require(await context.frames().first)
        let receiver = try await context.receiver(
            key: SymmetricKey(data: Data(repeating: 0x99, count: 32))
        )
        await #expect(throws: TransferProtocolError.authenticationFailed) {
            _ = try await receiver.accept(frame)
        }
        #expect(await receiver.resumeState().nextOffset == 0)
    }

    @Test("接收完成后文件被篡改，最终 SHA256 拒绝")
    func tamperedStagingFileFailsFinalHash() async throws {
        let context = try ChunkTestContext(data: patternedData(count: 70_000))
        defer { context.cleanup() }
        let receiver = try await context.receiver()
        for frame in try await context.frames() {
            _ = try await receiver.accept(frame)
        }
        var tampered = context.data
        tampered[0] ^= 0xFF
        try tampered.write(to: context.stagingURL, options: [])
        await #expect(
            throws: TransferProtocolError.fileHashMismatch(fileID: context.descriptor.fileID)
        ) {
            try await receiver.finalize()
        }
    }

    @Test("空原文件在建立分块读取器前即被拒绝")
    func emptyFileUsesNoChunk() async throws {
        #expect(throws: TransferProtocolError.self) {
            _ = try ChunkTestContext(data: Data())
        }
    }
}

private struct ChunkTestContext {
    let rootURL: URL
    let sourceURL: URL
    let stagingRootURL: URL
    let stagingURL: URL
    let stagingStore: TransferStagingStore
    let data: Data
    let transferID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let patientID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let fileID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let descriptor: TransferFileDescriptor
    let validatedDescriptor: ValidatedTransferFileDescriptor

    init(data: Data) throws {
        self.data = data
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyTransfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sourceURL = rootURL.appendingPathComponent("source.bin")
        stagingRootURL = rootURL.appendingPathComponent("staging", isDirectory: true)
        stagingURL = stagingRootURL
            .appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(fileID.uuidString.lowercased())
            .appendingPathExtension("partial")
        try data.write(to: sourceURL)
        descriptor = TransferFileDescriptor(
            kind: .originalAttachment,
            fileID: fileID,
            patientID: patientID,
            ownerAttachmentID: UUID(
                uuidString: "40000000-0000-0000-0000-000000000004"
            )!,
            relativePath: "members/\(patientID.uuidString.lowercased())/original.bin",
            byteCount: Int64(data.count),
            sha256: Data(SHA256.hash(data: data)).testHex
        )
        validatedDescriptor = try descriptor.validated()
        stagingStore = try TransferStagingStore(rootURL: stagingRootURL)
    }

    func frames() async throws -> [EncryptedChunkFrame] {
        let reader = try TransferFileChunkReader(
            fileURL: sourceURL,
            descriptor: validatedDescriptor,
            transferID: transferID,
            key: key
        )
        var frames: [EncryptedChunkFrame] = []
        while let frame = try await reader.nextFrame() {
            frames.append(frame)
        }
        return frames
    }

    func receiver(
        key: SymmetricKey? = nil,
        resumeFrom state: TransferResumeState? = nil
    ) async throws -> TransferFileChunkReceiver {
        try await TransferFileChunkReceiver.make(
            stagingStore: stagingStore,
            descriptor: validatedDescriptor,
            transferID: transferID,
            key: key ?? self.key,
            resumeFrom: state
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func patternedData(count: Int) -> Data {
    Data((0..<count).map { UInt8($0 % 251) })
}
