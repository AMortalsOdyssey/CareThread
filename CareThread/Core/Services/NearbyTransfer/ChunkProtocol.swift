import CryptoKit
import Foundation

struct TransferChunkHeader: Hashable, Sendable {
    let transferID: UUID
    let fileID: UUID
    let sequence: UInt64
    let offset: Int64
    let plaintextCount: Int
    let isFinal: Bool
}

struct EncryptedChunkFrame: Equatable, Sendable {
    let header: TransferChunkHeader
    let nonce: Data
    let ciphertext: Data
    let authenticationTag: Data
}

enum TransferChunkWireCodec {
    private static let magic = Data([0x43, 0x54, 0x43, 0x31]) // CTC1
    private static let version: UInt8 = 1
    private static let fixedBytesBeforeCiphertext = 76
    private static let tagBytes = 16
    static let maximumEncodedBytes = fixedBytesBeforeCiphertext
        + TransferLimits.chunkSize
        + tagBytes

    static func encode(_ frame: EncryptedChunkFrame) throws -> Data {
        try validateShape(frame)
        var output = try authenticatedHeader(frame.header)
        output.append(frame.nonce)
        output.appendUInt32(UInt32(frame.ciphertext.count))
        output.append(frame.ciphertext)
        output.append(frame.authenticationTag)
        guard output.count <= maximumEncodedBytes else {
            throw TransferProtocolError.limitExceeded("chunk wire frame")
        }
        return output
    }

    static func decode(_ data: Data) throws -> EncryptedChunkFrame {
        guard data.count >= fixedBytesBeforeCiphertext + tagBytes,
              data.count <= maximumEncodedBytes else {
            throw TransferProtocolError.invalidChunk("wire size")
        }
        var cursor = BinaryCursor(data)
        guard try cursor.readData(count: 4) == magic,
              try cursor.readUInt8() == version else {
            throw TransferProtocolError.invalidChunk("wire magic/version")
        }
        let flags = try cursor.readUInt8()
        guard flags == 0 || flags == 1,
              try cursor.readUInt16() == 0 else {
            throw TransferProtocolError.invalidChunk("wire flags")
        }
        let transferID = try cursor.readUUID()
        let fileID = try cursor.readUUID()
        let sequence = try cursor.readUInt64()
        let offsetBits = try cursor.readUInt64()
        let plaintextCount = Int(try cursor.readUInt32())
        let nonce = try cursor.readData(count: 12)
        let ciphertextCount = Int(try cursor.readUInt32())
        guard plaintextCount > 0,
              plaintextCount <= TransferLimits.chunkSize,
              ciphertextCount == plaintextCount,
              cursor.remaining == ciphertextCount + tagBytes else {
            throw TransferProtocolError.invalidChunk("wire payload size")
        }
        let frame = EncryptedChunkFrame(
            header: TransferChunkHeader(
                transferID: transferID,
                fileID: fileID,
                sequence: sequence,
                offset: Int64(bitPattern: offsetBits),
                plaintextCount: plaintextCount,
                isFinal: flags == 1
            ),
            nonce: nonce,
            ciphertext: try cursor.readData(count: ciphertextCount),
            authenticationTag: try cursor.readData(count: tagBytes)
        )
        try validateShape(frame)
        return frame
    }

    static func authenticatedHeader(_ header: TransferChunkHeader) throws -> Data {
        guard header.plaintextCount > 0,
              header.plaintextCount <= TransferLimits.chunkSize,
              header.offset >= 0 else {
            throw TransferProtocolError.invalidChunk("header bounds")
        }
        var output = Data()
        output.append(magic)
        output.append(version)
        output.append(header.isFinal ? 1 : 0)
        output.appendUInt16(0)
        output.appendUUID(header.transferID)
        output.appendUUID(header.fileID)
        output.appendUInt64(header.sequence)
        output.appendUInt64(UInt64(bitPattern: header.offset))
        output.appendUInt32(UInt32(header.plaintextCount))
        return output
    }

    private static func validateShape(_ frame: EncryptedChunkFrame) throws {
        guard frame.nonce.count == 12,
              frame.authenticationTag.count == tagBytes,
              frame.ciphertext.count == frame.header.plaintextCount else {
            throw TransferProtocolError.invalidChunk("encrypted frame shape")
        }
        _ = try authenticatedHeader(frame.header)
    }
}

enum TransferChunkCrypto {
    static func seal(
        plaintext: Data,
        header: TransferChunkHeader,
        using key: SymmetricKey
    ) throws -> EncryptedChunkFrame {
        guard !plaintext.isEmpty,
              plaintext.count == header.plaintextCount,
              plaintext.count <= TransferLimits.chunkSize else {
            throw TransferProtocolError.invalidChunk("plaintext size")
        }
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: TransferChunkWireCodec.authenticatedHeader(header)
        )
        return EncryptedChunkFrame(
            header: header,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            authenticationTag: sealed.tag
        )
    }

    static func open(_ frame: EncryptedChunkFrame, using key: SymmetricKey) throws -> Data {
        do {
            let nonce = try ChaChaPoly.Nonce(data: frame.nonce)
            let sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: frame.ciphertext,
                tag: frame.authenticationTag
            )
            return try ChaChaPoly.open(
                sealed,
                using: key,
                authenticating: TransferChunkWireCodec.authenticatedHeader(frame.header)
            )
        } catch let error as TransferProtocolError {
            throw error
        } catch {
            throw TransferProtocolError.authenticationFailed
        }
    }
}

struct TransferResumeState: Codable, Equatable, Sendable {
    let transferID: UUID
    let fileID: UUID
    let chunkSize: Int
    let totalChunkCount: Int
    private(set) var receivedBitmap: Data
    private(set) var nextOffset: Int64

    init(transferID: UUID, descriptor: ValidatedTransferFileDescriptor) {
        self.transferID = transferID
        fileID = descriptor.fileID
        chunkSize = descriptor.chunkSize
        totalChunkCount = descriptor.totalChunkCount
        receivedBitmap = Data(repeating: 0, count: (descriptor.totalChunkCount + 7) / 8)
        nextOffset = 0
    }

    func contains(sequence: UInt64) -> Bool {
        guard sequence < UInt64(totalChunkCount) else { return false }
        let index = Int(sequence)
        let byteIndex = index / 8
        let bit = UInt8(1 << (index % 8))
        return receivedBitmap[byteIndex] & bit != 0
    }

    mutating func mark(sequence: UInt64, nextOffset: Int64) throws {
        guard sequence < UInt64(totalChunkCount) else {
            throw TransferProtocolError.invalidChunk("sequence exceeds bitmap")
        }
        let index = Int(sequence)
        receivedBitmap[index / 8] |= UInt8(1 << (index % 8))
        self.nextOffset = nextOffset
    }

    func validate(
        for descriptor: ValidatedTransferFileDescriptor,
        transferID: UUID
    ) throws {
        guard self.transferID == transferID else {
            throw TransferProtocolError.transferMismatch
        }
        let expectedBitmapBytes = (descriptor.totalChunkCount + 7) / 8
        guard fileID == descriptor.fileID,
              chunkSize == TransferLimits.chunkSize,
              totalChunkCount == descriptor.totalChunkCount,
              totalChunkCount <= TransferLimits.maximumChunksPerFile,
              receivedBitmap.count == expectedBitmapBytes,
              receivedBitmap.count <= TransferLimits.maximumResumeBitmapBytes,
              nextOffset >= 0,
              nextOffset <= descriptor.byteCount else {
            throw TransferProtocolError.invalidChunk("invalid resume state")
        }
        let completedChunks: Int
        if nextOffset == 0 {
            completedChunks = 0
        } else {
            let numerator = nextOffset - 1
            completedChunks = Int(numerator / Int64(chunkSize)) + 1
        }
        for sequence in 0..<completedChunks where !contains(sequence: UInt64(sequence)) {
            throw TransferProtocolError.invalidChunk("resume bitmap has a gap")
        }
        for sequence in completedChunks..<totalChunkCount
        where contains(sequence: UInt64(sequence)) {
            throw TransferProtocolError.invalidChunk("resume bitmap exceeds next offset")
        }
        if nextOffset < descriptor.byteCount,
           nextOffset % Int64(chunkSize) != 0 {
            throw TransferProtocolError.invalidChunk("unaligned resume offset")
        }
    }
}

actor TransferFileChunkReader {
    private let transferID: UUID
    private let descriptor: ValidatedTransferFileDescriptor
    private let key: SymmetricKey
    private let handle: FileHandle
    private var sequence: UInt64
    private var offset: Int64
    private var finished = false

    init(
        fileURL: URL,
        descriptor: ValidatedTransferFileDescriptor,
        transferID: UUID,
        key: SymmetricKey,
        resumeFrom state: TransferResumeState? = nil
    ) throws {
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard fileURL.isFileURL,
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == descriptor.byteCount else {
            throw TransferProtocolError.fileSizeMismatch(fileID: descriptor.fileID)
        }
        self.transferID = transferID
        self.descriptor = descriptor
        self.key = key
        handle = try FileHandle(forReadingFrom: fileURL)

        if let state {
            try state.validate(for: descriptor, transferID: transferID)
            sequence = UInt64(state.nextOffset / Int64(descriptor.chunkSize))
            offset = state.nextOffset
        } else {
            sequence = 0
            offset = 0
        }
        try handle.seek(toOffset: UInt64(offset))
    }

    deinit {
        try? handle.close()
    }

    func nextFrame() throws -> EncryptedChunkFrame? {
        guard !finished else { return nil }
        guard offset < descriptor.byteCount else {
            finished = true
            return nil
        }
        let remaining = descriptor.byteCount - offset
        let readCount = min(TransferLimits.chunkSize, Int(remaining))
        guard let plaintext = try handle.read(upToCount: readCount),
              plaintext.count == readCount else {
            throw TransferProtocolError.fileSizeMismatch(fileID: descriptor.fileID)
        }
        let (nextOffset, overflow) = offset.addingReportingOverflow(Int64(plaintext.count))
        guard !overflow else {
            throw TransferProtocolError.invalidChunk("offset overflow")
        }
        let header = TransferChunkHeader(
            transferID: transferID,
            fileID: descriptor.fileID,
            sequence: sequence,
            offset: offset,
            plaintextCount: plaintext.count,
            isFinal: nextOffset == descriptor.byteCount
        )
        let frame = try TransferChunkCrypto.seal(
            plaintext: plaintext,
            header: header,
            using: key
        )
        sequence += 1
        offset = nextOffset
        if header.isFinal {
            finished = true
        }
        return frame
    }
}

enum TransferChunkAcceptance: Equatable, Sendable {
    case accepted(nextOffset: Int64)
    case duplicate(nextOffset: Int64)
}

actor TransferFileChunkReceiver {
    private let transferID: UUID
    private let descriptor: ValidatedTransferFileDescriptor
    private let key: SymmetricKey
    private let stagedFile: StagedTransferFile
    private let stagingStore: TransferStagingStore
    private let handle: FileHandle
    private var resume: TransferResumeState

    private init(
        stagedFile: StagedTransferFile,
        stagingStore: TransferStagingStore,
        transferID: UUID,
        key: SymmetricKey,
        resume: TransferResumeState,
        handle: FileHandle
    ) {
        self.transferID = transferID
        descriptor = stagedFile.descriptor
        self.key = key
        self.stagedFile = stagedFile
        self.stagingStore = stagingStore
        self.resume = resume
        self.handle = handle
    }

    static func make(
        stagingStore: TransferStagingStore,
        descriptor: ValidatedTransferFileDescriptor,
        transferID: UUID,
        key: SymmetricKey,
        resumeFrom state: TransferResumeState? = nil
    ) async throws -> TransferFileChunkReceiver {
        if let state {
            try state.validate(for: descriptor, transferID: transferID)
        }
        let staged = try await stagingStore.prepare(
            transferID: transferID,
            descriptor: descriptor,
            resume: state
        )
        let handle = try await stagingStore.openForUpdate(staged)
        return TransferFileChunkReceiver(
            stagedFile: staged,
            stagingStore: stagingStore,
            transferID: transferID,
            key: key,
            resume: state ?? TransferResumeState(
                transferID: transferID,
                descriptor: descriptor
            ),
            handle: handle
        )
    }

    deinit {
        try? handle.close()
    }

    func accept(_ frame: EncryptedChunkFrame) async throws -> TransferChunkAcceptance {
        let header = frame.header
        guard header.transferID == transferID else {
            throw TransferProtocolError.transferMismatch
        }
        guard header.fileID == descriptor.fileID else {
            throw TransferProtocolError.fileMismatch
        }
        guard header.sequence < UInt64(descriptor.totalChunkCount),
              header.sequence <= UInt64(Int64.max / Int64(TransferLimits.chunkSize)) else {
            throw TransferProtocolError.invalidChunk("sequence overflow")
        }
        let expectedHeaderOffset = Int64(header.sequence) * Int64(TransferLimits.chunkSize)
        let (chunkEnd, overflow) = header.offset.addingReportingOverflow(
            Int64(header.plaintextCount)
        )
        let expectedCount = min(
            TransferLimits.chunkSize,
            Int(descriptor.byteCount - expectedHeaderOffset)
        )
        guard !overflow,
              header.plaintextCount == expectedCount,
              header.offset == expectedHeaderOffset,
              chunkEnd <= descriptor.byteCount,
              header.isFinal == (chunkEnd == descriptor.byteCount) else {
            throw TransferProtocolError.invalidChunk("header bounds")
        }

        let expectedSequence = UInt64(resume.nextOffset / Int64(TransferLimits.chunkSize))
        if header.sequence > expectedSequence {
            throw TransferProtocolError.outOfOrder(
                expected: expectedSequence,
                received: header.sequence
            )
        }

        let plaintext = try TransferChunkCrypto.open(frame, using: key)
        guard plaintext.count == header.plaintextCount else {
            throw TransferProtocolError.invalidChunk("decrypted size")
        }

        if header.sequence < expectedSequence || resume.contains(sequence: header.sequence) {
            try handle.seek(toOffset: UInt64(header.offset))
            let existing = try handle.read(upToCount: header.plaintextCount)
            guard existing == plaintext else {
                throw TransferProtocolError.conflictingDuplicate(sequence: header.sequence)
            }
            return .duplicate(nextOffset: resume.nextOffset)
        }

        guard header.offset == resume.nextOffset else {
            throw TransferProtocolError.outOfOrder(
                expected: expectedSequence,
                received: header.sequence
            )
        }
        try await stagingStore.assertStillSafe(stagedFile)
        try handle.seek(toOffset: UInt64(header.offset))
        try handle.write(contentsOf: plaintext)
        try handle.seek(toOffset: UInt64(header.offset))
        guard try handle.read(upToCount: plaintext.count) == plaintext else {
            throw TransferProtocolError.transport("short or corrupt staging write")
        }
        let nextOffset = chunkEnd
        try resume.mark(sequence: header.sequence, nextOffset: nextOffset)
        let shouldCheckpoint = header.isFinal
            || (header.sequence + 1) % UInt64(TransferLimits.checkpointIntervalChunks) == 0
        if shouldCheckpoint {
            try handle.synchronize()
            try await stagingStore.checkpoint(stagedFile, resume: resume)
        }
        return .accepted(nextOffset: nextOffset)
    }

    func resumeState() -> TransferResumeState {
        resume
    }

    func finalize() async throws {
        guard resume.nextOffset == descriptor.byteCount else {
            throw TransferProtocolError.fileSizeMismatch(fileID: descriptor.fileID)
        }
        try handle.synchronize()
        let size = try handle.seekToEnd()
        guard size == UInt64(descriptor.byteCount) else {
            throw TransferProtocolError.fileSizeMismatch(fileID: descriptor.fileID)
        }
        try await stagingStore.checkpoint(stagedFile, resume: resume)
        try await stagingStore.assertStillSafe(stagedFile)
        let digest = try await stagingStore.hash(stagedFile)
        guard digest == descriptor.sha256 else {
            throw TransferProtocolError.fileHashMismatch(fileID: descriptor.fileID)
        }
        try await stagingStore.markVerified(stagedFile)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { append(contentsOf: $0) }
    }
}

private struct BinaryCursor {
    private let data: Data
    private(set) var offset = 0
    var remaining: Int { data.count - offset }

    init(_ data: Data) {
        self.data = data
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw TransferProtocolError.invalidChunk("truncated wire frame")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt8() throws -> UInt8 {
        try readData(count: 1)[0]
    }

    mutating func readUInt16() throws -> UInt16 {
        try readData(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        try readData(count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        try readData(count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUUID() throws -> UUID {
        var bytes = [UInt8](try readData(count: 16))
        return bytes.withUnsafeMutableBufferPointer {
            NSUUID(uuidBytes: $0.baseAddress!) as UUID
        }
    }
}
