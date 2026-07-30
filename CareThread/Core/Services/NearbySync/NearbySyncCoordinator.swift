import Foundation

enum NearbySyncCoordinatorEvent: Sendable {
    case state(TransferState)
    case pairingCode(alias: String, code: String)
    case manifestPreview(
        alias: String,
        preview: TransferPreviewCounts,
        totalByteCount: Int64
    )
    case progress(TransferProgress)
    case result(NearbySyncImportResult)
}

struct NearbySyncSenderResult: Equatable, Sendable {
    let transferID: UUID
    let resultSHA256: String
}

actor NearbySyncSenderCoordinator {
    let events: AsyncStream<NearbySyncCoordinatorEvent>

    private let transport: any NearbyByteTransport
    private let session: NearbyTransferSession
    private let sessionID: UUID
    private let package: NearbySyncExportPackage
    private let localAlias: String
    private let pump = NearbySyncConnectionPump()
    private let continuation: AsyncStream<NearbySyncCoordinatorEvent>.Continuation
    private var machine = TransferStateMachine(role: .sender)
    private var cancelled = false

    init(
        transport: any NearbyByteTransport,
        package: NearbySyncExportPackage,
        sessionID: UUID = UUID(),
        localAlias: String = NearbyNetworkConfiguration.randomSessionName()
    ) throws {
        guard NearbySyncAlias.isValid(localAlias) else {
            throw TransferProtocolError.invalidManifest("sender alias")
        }
        self.transport = transport
        self.package = package
        self.localAlias = localAlias
        self.sessionID = sessionID
        session = try NearbyTransferSession(
            role: .sender,
            sessionID: sessionID,
            transferID: package.manifest.transferID
        )
        let pair = AsyncStream.makeStream(
            of: NearbySyncCoordinatorEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func run(
        confirmPairing: @escaping @Sendable (String) async -> Bool
    ) async throws -> NearbySyncSenderResult {
        do {
            try transition(.discovering)
            try transition(.connecting)
            transport.start()
            pump.start(transport)
            try transition(.pairing)
            try await send(
                .bootstrap(
                    .init(
                        protocolVersion: TransferLimits.protocolVersion,
                        sessionID: sessionID,
                        transferID: package.manifest.transferID,
                        senderAlias: localAlias
                    )
                )
            )
            guard case let .bootstrapAcknowledgement(bootstrapAck) =
                try await receive(.handshake),
                  bootstrapAck.protocolVersion == TransferLimits.protocolVersion,
                  bootstrapAck.sessionID == sessionID,
                  bootstrapAck.transferID == package.manifest.transferID,
                  NearbySyncAlias.isValid(bootstrapAck.receiverAlias) else {
                throw TransferProtocolError.invalidManifest("bootstrap mismatch")
            }
            try await send(.hello(await session.localHello()))
            guard case let .hello(peerHello) = try await receive(.handshake) else {
                throw TransferProtocolError.invalidStateTransition
            }
            try await session.receivePeerHello(peerHello)
            let code = try await session.pairingCode()
            try transition(.awaitingPairingConfirmation)
            continuation.yield(
                .pairingCode(alias: bootstrapAck.receiverAlias, code: code)
            )
            guard await confirmPairing(code), !cancelled else {
                throw TransferProtocolError.cancelled
            }
            let confirmation = try await session.confirmPairing(codeMatches: true)
            try await send(.keyConfirmation(confirmation))
            guard case let .keyConfirmation(peerConfirmation) =
                try await receive(.handshake) else {
                throw TransferProtocolError.invalidStateTransition
            }
            try await session.receivePeerKeyConfirmation(peerConfirmation)
            guard await session.isAuthorizedForSensitiveFrames() else {
                throw TransferProtocolError.pairingNotConfirmed
            }

            try transition(.negotiating)
            // Security invariant: the manifest is created and sent only after
            // local SAS confirmation and authenticated peer confirmation.
            let sealed = try await session.sealOutgoingManifest(package.manifest)
            try await send(.manifest(sealed))
            guard case let .manifestDecision(decision) =
                try await receive(.stage),
                  decision.transferID == package.manifest.transferID,
                  decision.accepted else {
                throw TransferProtocolError.cancelled
            }

            let descriptors = try package.manifest.files.map { try $0.validated() }
            let zero = try TransferProgress(
                completedBytes: 0,
                totalBytes: package.manifest.totalByteCount
            )
            try transition(.transferring(zero))
            continuation.yield(.progress(zero))

            var completed = decision.alreadyCommitted
                ? package.manifest.totalByteCount
                : 0
            if decision.alreadyCommitted {
                try await send(
                    .transferFinished(.init(transferID: package.manifest.transferID))
                )
            } else {
                let key = try await session.outgoingChunkKey()
                for descriptor in descriptors {
                    if cancelled { throw TransferProtocolError.cancelled }
                    try await send(
                        .resumeQuery(
                            .init(
                                transferID: package.manifest.transferID,
                                fileID: descriptor.fileID
                            )
                        )
                    )
                    guard case let .resumeResponse(response) =
                        try await receive(.stage),
                          response.transferID == package.manifest.transferID,
                          response.state.fileID == descriptor.fileID else {
                        throw TransferProtocolError.fileMismatch
                    }
                    try response.state.validate(
                        for: descriptor,
                        transferID: package.manifest.transferID
                    )
                    let resume = response.state
                    completed += resume.nextOffset
                    if resume.nextOffset > 0 {
                        let resumedProgress = try TransferProgress(
                            completedBytes: completed,
                            totalBytes: package.manifest.totalByteCount
                        )
                        try transition(.transferring(resumedProgress))
                        continuation.yield(.progress(resumedProgress))
                    }
                    let reader = try TransferFileChunkReader(
                        fileURL: package.fileURL(for: descriptor.fileID),
                        descriptor: descriptor,
                        transferID: package.manifest.transferID,
                        key: key,
                        resumeFrom: resume
                    )
                    while let frame = try await reader.nextFrame() {
                        try await send(.chunk(frame))
                        guard case let .chunkAcknowledgement(ack) =
                            try await receive(.send),
                              ack.transferID == package.manifest.transferID,
                              ack.fileID == descriptor.fileID,
                              ack.sequence == frame.header.sequence,
                              ack.nextOffset
                                == frame.header.offset + Int64(frame.header.plaintextCount)
                        else {
                            throw TransferProtocolError.invalidChunk("ack mismatch")
                        }
                        completed += Int64(frame.header.plaintextCount)
                        let progress = try TransferProgress(
                            completedBytes: completed,
                            totalBytes: package.manifest.totalByteCount
                        )
                        try transition(.transferring(progress))
                        continuation.yield(.progress(progress))
                    }
                }
                try await send(
                    .transferFinished(.init(transferID: package.manifest.transferID))
                )
            }
            let finalProgress = try TransferProgress(
                completedBytes: package.manifest.totalByteCount,
                totalBytes: package.manifest.totalByteCount
            )
            if completed != package.manifest.totalByteCount {
                try transition(.transferring(finalProgress))
                continuation.yield(.progress(finalProgress))
            }
            try transition(.verifying)
            try transition(.awaitingCommitReceipt)
            guard case let .commitReceipt(receipt) = try await receive(.stage) else {
                throw TransferProtocolError.invalidCommitReceipt
            }
            let verified = try await TransferCommitCoordinator.verifyOnSender(
                receipt,
                expectedTransferID: package.manifest.transferID,
                expectedManifestSHA256: sealed.manifestSHA256,
                session: session
            )
            try machine.acceptVerifiedCommitReceipt(verified)
            continuation.yield(.state(machine.state))
            continuation.finish()
            pump.stop()
            return NearbySyncSenderResult(
                transferID: verified.transferID,
                resultSHA256: verified.resultSHA256
            )
        } catch {
            await fail(error)
            throw error
        }
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        if let encoded = try? NearbySyncWireCodec.encode(
            .cancel(
                .init(
                    transferID: package.manifest.transferID,
                    reason: "user"
                )
            )
        ) {
            try? await TransferDeadline.run(
                operation: .send,
                nanoseconds: 1_000_000_000
            ) { [transport] in
                try await transport.send(
                    encoded.data,
                    category: encoded.category
                )
            }
        }
        transport.cancel()
        pump.stop()
        if !machine.state.isTerminal {
            try? transition(.cancelled)
        }
    }

    private func send(_ message: NearbySyncWireMessage) async throws {
        if cancelled { throw TransferProtocolError.cancelled }
        let encoded = try NearbySyncWireCodec.encode(message)
        try await TransferDeadline.run(operation: .send) { [transport] in
            try await transport.send(encoded.data, category: encoded.category)
        }
    }

    private func receive(
        _ operation: TransferDeadlineOperation
    ) async throws -> NearbySyncWireMessage {
        let message = try await TransferDeadline.run(operation: operation) { [pump] in
            try await pump.inbox.next()
        }
        if case .cancel = message { throw TransferProtocolError.cancelled }
        return message
    }

    private func transition(_ state: TransferState) throws {
        try machine.transition(to: state)
        continuation.yield(.state(machine.state))
    }

    private func fail(_ error: Error) async {
        if !machine.state.isTerminal {
            if let protocolError = error as? TransferProtocolError {
                try? transition(.failed(protocolError))
            } else {
                try? transition(.failed(.transport(String(describing: error))))
            }
        }
        transport.cancel()
        pump.stop()
        continuation.finish()
    }
}

actor NearbySyncReceiverCoordinator {
    let events: AsyncStream<NearbySyncCoordinatorEvent>

    private let transport: any NearbyByteTransport
    private let stagingStore: TransferStagingStore
    private let existingPatientIDs: Set<UUID>
    private let receiverAlias: String
    private let importer: @Sendable (VerifiedTransfer) async throws -> String
    private let pump = NearbySyncConnectionPump()
    private let continuation: AsyncStream<NearbySyncCoordinatorEvent>.Continuation
    private var machine = TransferStateMachine(role: .receiver)
    private var cancelled = false
    private var activeTransferID: UUID?

    init(
        transport: any NearbyByteTransport,
        stagingStore: TransferStagingStore,
        existingPatientIDs: Set<UUID>,
        receiverAlias: String = NearbyNetworkConfiguration.randomSessionName(),
        importer: @escaping @Sendable (VerifiedTransfer) async throws -> String
    ) throws {
        guard NearbySyncAlias.isValid(receiverAlias) else {
            throw TransferProtocolError.invalidManifest("receiver alias")
        }
        self.transport = transport
        self.stagingStore = stagingStore
        self.existingPatientIDs = existingPatientIDs
        self.receiverAlias = receiverAlias
        self.importer = importer
        let pair = AsyncStream.makeStream(
            of: NearbySyncCoordinatorEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func run(
        confirmPairing: @escaping @Sendable (String) async -> Bool,
        confirmManifest: @escaping @Sendable (TransferManifest) async -> Bool
    ) async throws -> NearbySyncImportResult {
        do {
            try transition(.discovering)
            try transition(.connecting)
            transport.start()
            pump.start(transport)
            try transition(.pairing)
            guard case let .bootstrap(bootstrap) = try await receive(.handshake),
                  bootstrap.protocolVersion == TransferLimits.protocolVersion,
                  NearbySyncAlias.isValid(bootstrap.senderAlias) else {
                throw TransferProtocolError.invalidManifest("bootstrap mismatch")
            }
            activeTransferID = bootstrap.transferID
            let session = try NearbyTransferSession(
                role: .receiver,
                sessionID: bootstrap.sessionID,
                transferID: bootstrap.transferID
            )
            try await send(
                .bootstrapAcknowledgement(
                    .init(
                        protocolVersion: TransferLimits.protocolVersion,
                        sessionID: bootstrap.sessionID,
                        transferID: bootstrap.transferID,
                        receiverAlias: receiverAlias
                    )
                )
            )
            try await send(.hello(await session.localHello()))
            guard case let .hello(peerHello) = try await receive(.handshake) else {
                throw TransferProtocolError.invalidStateTransition
            }
            try await session.receivePeerHello(peerHello)
            let code = try await session.pairingCode()
            try transition(.awaitingPairingConfirmation)
            continuation.yield(
                .pairingCode(alias: bootstrap.senderAlias, code: code)
            )
            guard await confirmPairing(code), !cancelled else {
                throw TransferProtocolError.cancelled
            }
            let confirmation = try await session.confirmPairing(codeMatches: true)
            try await send(.keyConfirmation(confirmation))
            guard case let .keyConfirmation(peerConfirmation) =
                try await receive(.handshake) else {
                throw TransferProtocolError.invalidStateTransition
            }
            try await session.receivePeerKeyConfirmation(peerConfirmation)
            guard await session.isAuthorizedForSensitiveFrames() else {
                throw TransferProtocolError.pairingNotConfirmed
            }

            try transition(.negotiating)
            guard case let .manifest(sealed) = try await receive(.stage) else {
                throw TransferProtocolError.invalidStateTransition
            }
            let manifest = try await session.openIncomingManifest(
                sealed,
                existingPatientIDs: existingPatientIDs
            )
            guard manifest.capabilities.contains(NearbySyncContract.capability),
                  manifest.totalByteCount <= NearbySyncContract.maximumTransferBytes else {
                throw NearbySyncError.malformedPayload
            }
            continuation.yield(
                .manifestPreview(
                    alias: bootstrap.senderAlias,
                    preview: manifest.preview,
                    totalByteCount: manifest.totalByteCount
                )
            )
            let accepted = await confirmManifest(manifest)
            let descriptors = try manifest.files.map { try $0.validated() }
            let committed = await stagingStore.committedReceipt(
                transferID: manifest.transferID
            ) != nil
            try await send(
                .manifestDecision(
                    .init(
                        transferID: manifest.transferID,
                        accepted: accepted,
                        receiverAlias: receiverAlias,
                        alreadyCommitted: committed
                    )
                )
            )
            guard accepted, !cancelled else {
                throw TransferProtocolError.cancelled
            }

            let zero = try TransferProgress(
                completedBytes: 0,
                totalBytes: manifest.totalByteCount
            )
            try transition(.transferring(zero))
            continuation.yield(.progress(zero))
            var completed: Int64 = committed
                ? manifest.totalByteCount
                : 0
            if !committed {
                let key = try await session.incomingChunkKey()
                for descriptor in descriptors {
                    guard case let .resumeQuery(query) = try await receive(.stage),
                          query.transferID == manifest.transferID,
                          query.fileID == descriptor.fileID else {
                        throw TransferProtocolError.fileMismatch
                    }
                    let resume = try await stagingStore.resumeState(
                        transferID: manifest.transferID,
                        descriptor: descriptor
                    ) ?? TransferResumeState(
                        transferID: manifest.transferID,
                        descriptor: descriptor
                    )
                    try await send(
                        .resumeResponse(
                            .init(transferID: manifest.transferID, state: resume)
                        )
                    )
                    completed += resume.nextOffset
                    if resume.nextOffset > 0 {
                        let resumedProgress = try TransferProgress(
                            completedBytes: completed,
                            totalBytes: manifest.totalByteCount
                        )
                        try transition(.transferring(resumedProgress))
                        continuation.yield(.progress(resumedProgress))
                    }
                    let receiver = try await TransferFileChunkReceiver.make(
                        stagingStore: stagingStore,
                        descriptor: descriptor,
                        transferID: manifest.transferID,
                        key: key,
                        resumeFrom: resume
                    )
                    while (await receiver.resumeState()).nextOffset < descriptor.byteCount {
                        guard case let .chunk(frame) = try await receive(.stage) else {
                            throw TransferProtocolError.invalidChunk("expected chunk")
                        }
                        let previousOffset = (await receiver.resumeState()).nextOffset
                        let acceptance = try await receiver.accept(frame)
                        let nextOffset: Int64
                        switch acceptance {
                        case let .accepted(offset), let .duplicate(offset):
                            nextOffset = offset
                        }
                        try await send(
                            .chunkAcknowledgement(
                                .init(
                                    transferID: manifest.transferID,
                                    fileID: descriptor.fileID,
                                    sequence: frame.header.sequence,
                                    nextOffset: nextOffset
                                )
                            )
                        )
                        completed += nextOffset - previousOffset
                        let progress = try TransferProgress(
                            completedBytes: min(completed, manifest.totalByteCount),
                            totalBytes: manifest.totalByteCount
                        )
                        try transition(.transferring(progress))
                        continuation.yield(.progress(progress))
                    }
                    try await receiver.finalize()
                }
            }
            guard case let .transferFinished(finished) = try await receive(.stage),
                  finished.transferID == manifest.transferID else {
                throw TransferProtocolError.transferMismatch
            }
            let finalProgress = try TransferProgress(
                completedBytes: manifest.totalByteCount,
                totalBytes: manifest.totalByteCount
            )
            if completed != manifest.totalByteCount {
                try transition(.transferring(finalProgress))
                continuation.yield(.progress(finalProgress))
            }
            try transition(.verifying)
            let verified = try await TransferIntegrityVerifier.verifyCommitReadiness(
                sealedManifest: sealed,
                session: session,
                stagingStore: stagingStore,
                existingPatientIDs: existingPatientIDs
            )
            try transition(.commitReady)
            try transition(.committing)
            let receipt = try await TransferCommitCoordinator.commitOnReceiver(
                verified,
                stagingStore: stagingStore,
                session: session,
                committedAtUTC: ISO8601DateFormatter().string(from: Date()),
                importer: importer
            )
            try await send(.commitReceipt(receipt))
            try transition(.completed)
            let result = NearbySyncImportResult(
                transferID: verified.plan.transferID,
                insertedEntityCount: verified.plan.entityCount,
                idempotentEntityCount: 0,
                resultSHA256: receipt.resultSHA256
            )
            continuation.yield(.result(result))
            continuation.finish()
            pump.stop()
            return result
        } catch {
            await fail(error)
            throw error
        }
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        if let activeTransferID,
           let encoded = try? NearbySyncWireCodec.encode(
               .cancel(
                   .init(
                       transferID: activeTransferID,
                       reason: "user"
                   )
               )
           ) {
            try? await TransferDeadline.run(
                operation: .send,
                nanoseconds: 1_000_000_000
            ) { [transport] in
                try await transport.send(
                    encoded.data,
                    category: encoded.category
                )
            }
        }
        transport.cancel()
        pump.stop()
        if !machine.state.isTerminal {
            try? transition(.cancelled)
        }
    }

    private func send(_ message: NearbySyncWireMessage) async throws {
        if cancelled { throw TransferProtocolError.cancelled }
        let encoded = try NearbySyncWireCodec.encode(message)
        try await TransferDeadline.run(operation: .send) { [transport] in
            try await transport.send(encoded.data, category: encoded.category)
        }
    }

    private func receive(
        _ operation: TransferDeadlineOperation
    ) async throws -> NearbySyncWireMessage {
        let message = try await TransferDeadline.run(operation: operation) { [pump] in
            try await pump.inbox.next()
        }
        if case .cancel = message { throw TransferProtocolError.cancelled }
        return message
    }

    private func transition(_ state: TransferState) throws {
        try machine.transition(to: state)
        continuation.yield(.state(machine.state))
    }

    private func fail(_ error: Error) async {
        if !machine.state.isTerminal {
            if let protocolError = error as? TransferProtocolError {
                try? transition(.failed(protocolError))
            } else {
                try? transition(.failed(.transport(String(describing: error))))
            }
        }
        transport.cancel()
        pump.stop()
        continuation.finish()
    }
}

private enum NearbySyncAlias {
    static func isValid(_ value: String) -> Bool {
        value.range(
            of: "^ct-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil
    }
}
