import Foundation

enum NearbySyncWireKind: UInt8, Sendable {
    case hello = 1
    case keyConfirmation = 2
    case manifest = 3
    case manifestDecision = 4
    case chunkAcknowledgement = 5
    case transferFinished = 6
    case commitReceipt = 7
    case cancel = 8
    case bootstrap = 9
    case bootstrapAcknowledgement = 10
    case resumeQuery = 11
    case resumeResponse = 12
}

struct NearbySyncBootstrap: Codable, Sendable {
    let protocolVersion: Int
    let sessionID: UUID
    let transferID: UUID
    let senderAlias: String
}

struct NearbySyncBootstrapAcknowledgement: Codable, Sendable {
    let protocolVersion: Int
    let sessionID: UUID
    let transferID: UUID
    let receiverAlias: String
}

struct NearbySyncManifestDecision: Codable, Sendable {
    let transferID: UUID
    let accepted: Bool
    let receiverAlias: String
    let alreadyCommitted: Bool
}

struct NearbySyncResumeQuery: Codable, Sendable {
    let transferID: UUID
    let fileID: UUID
}

struct NearbySyncResumeResponse: Codable, Sendable {
    let transferID: UUID
    let state: TransferResumeState
}

struct NearbySyncChunkAcknowledgement: Codable, Equatable, Sendable {
    let transferID: UUID
    let fileID: UUID
    let sequence: UInt64
    let nextOffset: Int64
}

struct NearbySyncTransferFinished: Codable, Sendable {
    let transferID: UUID
}

struct NearbySyncCancelMessage: Codable, Sendable {
    let transferID: UUID
    let reason: String
}

enum NearbySyncWireMessage: Sendable {
    case bootstrap(NearbySyncBootstrap)
    case bootstrapAcknowledgement(NearbySyncBootstrapAcknowledgement)
    case hello(TransferSessionHello)
    case keyConfirmation(TransferKeyConfirmation)
    case manifest(SealedTransferManifest)
    case manifestDecision(NearbySyncManifestDecision)
    case resumeQuery(NearbySyncResumeQuery)
    case resumeResponse(NearbySyncResumeResponse)
    case chunk(EncryptedChunkFrame)
    case chunkAcknowledgement(NearbySyncChunkAcknowledgement)
    case transferFinished(NearbySyncTransferFinished)
    case commitReceipt(TransferCommitReceipt)
    case cancel(NearbySyncCancelMessage)
}

enum NearbySyncWireCodec {
    private static let controlMagic = Data([0x4e, 0x53, 0x59, 0x31]) // NSY1
    private static let chunkMagic = Data([0x43, 0x54, 0x43, 0x31]) // CTC1
    private static let headerBytes = 5

    static func encode(_ message: NearbySyncWireMessage) throws -> (
        data: Data,
        category: NearbyWireFrameCategory
    ) {
        switch message {
        case let .chunk(frame):
            return (try TransferChunkWireCodec.encode(frame), .chunk)
        case let .bootstrap(value):
            return try control(.bootstrap, value, .handshake)
        case let .bootstrapAcknowledgement(value):
            return try control(.bootstrapAcknowledgement, value, .handshake)
        case let .hello(value):
            return try control(.hello, value, .handshake)
        case let .keyConfirmation(value):
            return try control(.keyConfirmation, value, .handshake)
        case let .manifest(value):
            return try control(.manifest, value, .manifest)
        case let .manifestDecision(value):
            return try control(.manifestDecision, value, .control)
        case let .resumeQuery(value):
            return try control(.resumeQuery, value, .control)
        case let .resumeResponse(value):
            return try control(.resumeResponse, value, .control)
        case let .chunkAcknowledgement(value):
            return try control(.chunkAcknowledgement, value, .control)
        case let .transferFinished(value):
            return try control(.transferFinished, value, .control)
        case let .commitReceipt(value):
            return try control(.commitReceipt, value, .commitReceipt)
        case let .cancel(value):
            return try control(.cancel, value, .control)
        }
    }

    static func decode(_ data: Data) throws -> NearbySyncWireMessage {
        guard !data.isEmpty else {
            throw TransferProtocolError.invalidChunk("empty application frame")
        }
        if data.prefix(4) == chunkMagic {
            return .chunk(try TransferChunkWireCodec.decode(data))
        }
        guard data.count > headerBytes,
              data.prefix(4) == controlMagic,
              let kind = NearbySyncWireKind(rawValue: data[4]) else {
            throw TransferProtocolError.invalidChunk("application frame header")
        }
        let body = data.dropFirst(headerBytes)
        do {
            switch kind {
            case .bootstrap:
                return .bootstrap(
                    try StableJSON.decode(NearbySyncBootstrap.self, from: Data(body))
                )
            case .bootstrapAcknowledgement:
                return .bootstrapAcknowledgement(
                    try StableJSON.decode(
                        NearbySyncBootstrapAcknowledgement.self,
                        from: Data(body)
                    )
                )
            case .hello:
                return .hello(
                    try StableJSON.decode(TransferSessionHello.self, from: Data(body))
                )
            case .keyConfirmation:
                return .keyConfirmation(
                    try StableJSON.decode(TransferKeyConfirmation.self, from: Data(body))
                )
            case .manifest:
                return .manifest(
                    try StableJSON.decode(SealedTransferManifest.self, from: Data(body))
                )
            case .manifestDecision:
                return .manifestDecision(
                    try StableJSON.decode(
                        NearbySyncManifestDecision.self,
                        from: Data(body)
                    )
                )
            case .resumeQuery:
                return .resumeQuery(
                    try StableJSON.decode(NearbySyncResumeQuery.self, from: Data(body))
                )
            case .resumeResponse:
                return .resumeResponse(
                    try StableJSON.decode(
                        NearbySyncResumeResponse.self,
                        from: Data(body)
                    )
                )
            case .chunkAcknowledgement:
                return .chunkAcknowledgement(
                    try StableJSON.decode(
                        NearbySyncChunkAcknowledgement.self,
                        from: Data(body)
                    )
                )
            case .transferFinished:
                return .transferFinished(
                    try StableJSON.decode(
                        NearbySyncTransferFinished.self,
                        from: Data(body)
                    )
                )
            case .commitReceipt:
                return .commitReceipt(
                    try StableJSON.decode(TransferCommitReceipt.self, from: Data(body))
                )
            case .cancel:
                return .cancel(
                    try StableJSON.decode(NearbySyncCancelMessage.self, from: Data(body))
                )
            }
        } catch let error as TransferProtocolError {
            throw error
        } catch {
            throw TransferProtocolError.invalidChunk("malformed application frame")
        }
    }

    private static func control<T: Encodable>(
        _ kind: NearbySyncWireKind,
        _ value: T,
        _ category: NearbyWireFrameCategory
    ) throws -> (Data, NearbyWireFrameCategory) {
        let body = try StableJSON.encode(value)
        guard body.count <= category.maximumPayloadBytes - headerBytes else {
            throw TransferProtocolError.limitExceeded("application frame")
        }
        var data = controlMagic
        data.append(kind.rawValue)
        data.append(body)
        return (data, category)
    }
}

actor NearbySyncInbox {
    private var buffered: [NearbySyncWireMessage] = []
    private var waiters: [
        UUID: CheckedContinuation<NearbySyncWireMessage, Error>
    ] = [:]
    private var waiterOrder: [UUID] = []
    private var terminalError: Error?

    func enqueue(_ message: NearbySyncWireMessage) {
        if let id = waiterOrder.first,
           let continuation = waiters.removeValue(forKey: id) {
            waiterOrder.removeFirst()
            continuation.resume(returning: message)
        } else if buffered.count < 16 {
            buffered.append(message)
        } else {
            finish(TransferProtocolError.transport("application backpressure limit"))
        }
    }

    func finish(_ error: Error = TransferProtocolError.cancelled) {
        guard terminalError == nil else { return }
        terminalError = error
        let values = waiters.values
        waiters.removeAll()
        waiterOrder.removeAll()
        for continuation in values {
            continuation.resume(throwing: error)
        }
    }

    func next() async throws -> NearbySyncWireMessage {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if let terminalError { throw terminalError }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                waiterOrder.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: TransferProtocolError.cancelled)
    }
}

final class NearbySyncConnectionPump: @unchecked Sendable {
    let inbox = NearbySyncInbox()
    private var task: Task<Void, Never>?

    func start<T: NearbyByteTransport>(_ transport: T) {
        task = Task { [inbox] in
            do {
                for await data in transport.incomingFrames {
                    try Task.checkCancellation()
                    await inbox.enqueue(try NearbySyncWireCodec.decode(data))
                }
                await inbox.finish(TransferProtocolError.transport("peer closed"))
            } catch {
                await inbox.finish(error)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { await inbox.finish() }
    }

    deinit {
        task?.cancel()
    }
}
