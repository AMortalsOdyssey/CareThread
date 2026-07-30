import Foundation
import SwiftData

struct NearbySyncFlowPeer: Identifiable, Equatable, Sendable {
    let id: UUID
    let alias: String
}

enum NearbySyncDiscoveryEvent: Sendable {
    case ready
    case peers([NearbySyncFlowPeer])
    case waiting(String)
    case failed(String)
    case cancelled
}

final class NearbySyncFlowInvitation: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private let acceptAction: @Sendable () throws -> any NearbyByteTransport
    private let rejectAction: @Sendable () -> Void

    init(
        accept: @escaping @Sendable () throws -> any NearbyByteTransport,
        reject: @escaping @Sendable () -> Void
    ) {
        acceptAction = accept
        rejectAction = reject
    }

    func accept() throws -> any NearbyByteTransport {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            throw TransferProtocolError.transport("invitation already resolved")
        }
        resolved = true
        lock.unlock()
        return try acceptAction()
    }

    func reject() {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        rejectAction()
    }
}

enum NearbySyncListeningEvent: Sendable {
    case ready(alias: String)
    case invitation(NearbySyncFlowInvitation)
    case waiting(String)
    case failed(String)
    case cancelled
}

protocol NearbySyncBrowsing: AnyObject, Sendable {
    var events: AsyncStream<NearbySyncDiscoveryEvent> { get }
    func start()
    func transport(for peerID: UUID) throws -> any NearbyByteTransport
    func cancel()
}

protocol NearbySyncListening: AnyObject, Sendable {
    var events: AsyncStream<NearbySyncListeningEvent> { get }
    var alias: String { get }
    func start()
    func cancel()
}

protocol NearbySyncFlowNetworkFactory: Sendable {
    func makeBrowser() throws -> any NearbySyncBrowsing
    func makeListener() throws -> any NearbySyncListening
}

struct ProductionNearbySyncFlowNetworkFactory: NearbySyncFlowNetworkFactory {
    func makeBrowser() throws -> any NearbySyncBrowsing {
        ProductionNearbySyncBrowser()
    }

    func makeListener() throws -> any NearbySyncListening {
        try ProductionNearbySyncListener()
    }
}

private final class ProductionNearbySyncBrowser: NearbySyncBrowsing,
    @unchecked Sendable {
    let events: AsyncStream<NearbySyncDiscoveryEvent>

    private let bridge: NearbyBrowserBridge
    private let continuation: AsyncStream<NearbySyncDiscoveryEvent>.Continuation
    private let lock = NSLock()
    private var peers: [UUID: NearbyDiscoveredPeer] = [:]
    private var task: Task<Void, Never>?

    init(bridge: NearbyBrowserBridge = NearbyBrowserBridge()) {
        self.bridge = bridge
        let pair = AsyncStream.makeStream(
            of: NearbySyncDiscoveryEvent.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        events = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        task = Task { [weak self, bridge] in
            for await event in bridge.events {
                guard let self else { return }
                switch event {
                case .ready:
                    continuation.yield(.ready)
                case let .peers(discovered):
                    let sorted = discovered.sorted { $0.sessionName < $1.sessionName }
                    var mapped: [UUID: NearbyDiscoveredPeer] = [:]
                    var publicPeers: [NearbySyncFlowPeer] = []
                    for peer in sorted {
                        let id = Self.opaqueID(for: peer.sessionName)
                        mapped[id] = peer
                        publicPeers.append(.init(id: id, alias: peer.sessionName))
                    }
                    replacePeers(mapped)
                    continuation.yield(.peers(publicPeers))
                case let .waiting(reason):
                    continuation.yield(.waiting(reason))
                case let .failed(reason):
                    continuation.yield(.failed(reason))
                    continuation.finish()
                case .cancelled:
                    continuation.yield(.cancelled)
                    continuation.finish()
                }
            }
        }
    }

    func start() {
        bridge.start()
    }

    func transport(for peerID: UUID) throws -> any NearbyByteTransport {
        lock.lock()
        let peer = peers[peerID]
        lock.unlock()
        guard let peer else {
            throw TransferProtocolError.transport("selected peer disappeared")
        }
        return try NetworkNearbyByteTransport(peer: peer)
    }

    func cancel() {
        task?.cancel()
        task = nil
        bridge.cancel()
        continuation.finish()
        lock.lock()
        peers.removeAll()
        lock.unlock()
    }

    private func replacePeers(_ value: [UUID: NearbyDiscoveredPeer]) {
        lock.lock()
        peers = value
        lock.unlock()
    }

    private static func opaqueID(for alias: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in alias.utf8.enumerated() {
            bytes[index % bytes.count] = bytes[index % bytes.count] &+ byte
            bytes[(index * 7) % bytes.count] ^= byte
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    deinit {
        task?.cancel()
        bridge.cancel()
    }
}

private final class ProductionNearbySyncListener: NearbySyncListening,
    @unchecked Sendable {
    let events: AsyncStream<NearbySyncListeningEvent>
    let alias: String

    private let bridge: NearbyListenerBridge
    private let continuation: AsyncStream<NearbySyncListeningEvent>.Continuation
    private let invitationLock = NSLock()
    private var invitationIssued = false
    private var task: Task<Void, Never>?

    init(bridge: NearbyListenerBridge? = nil) throws {
        let resolvedBridge = try bridge ?? NearbyListenerBridge()
        self.bridge = resolvedBridge
        alias = resolvedBridge.sessionName
        let pair = AsyncStream.makeStream(
            of: NearbySyncListeningEvent.self,
            bufferingPolicy: .bufferingOldest(8)
        )
        events = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        task = Task { [weak self, resolvedBridge] in
            for await event in resolvedBridge.events {
                guard let self else { return }
                switch event {
                case .ready:
                    continuation.yield(.ready(alias: alias))
                case let .invitation(invitation):
                    let shouldIssue = claimInvitationSlot()
                    guard shouldIssue else {
                        invitation.reject()
                        continue
                    }
                    let wrapped = NearbySyncFlowInvitation(
                        accept: {
                            try NetworkNearbyByteTransport(invitation: invitation)
                        },
                        reject: { invitation.reject() }
                    )
                    if case .dropped = continuation.yield(.invitation(wrapped)) {
                        wrapped.reject()
                    }
                case let .waiting(reason):
                    continuation.yield(.waiting(reason))
                case let .failed(reason):
                    continuation.yield(.failed(reason))
                    continuation.finish()
                case .cancelled:
                    continuation.yield(.cancelled)
                    continuation.finish()
                }
            }
        }
    }

    func start() {
        bridge.start()
    }

    func cancel() {
        task?.cancel()
        task = nil
        bridge.cancel()
        continuation.finish()
    }

    private func claimInvitationSlot() -> Bool {
        invitationLock.lock()
        defer { invitationLock.unlock() }
        guard !invitationIssued else { return false }
        invitationIssued = true
        return true
    }

    deinit {
        task?.cancel()
        bridge.cancel()
    }
}

enum NearbySyncFlowEvent: Sendable {
    case discovering(peers: [NearbySyncFlowPeer])
    case waiting(alias: String?)
    case coordinator(NearbySyncCoordinatorEvent)
    case completed(resultSHA256: String)
    case failed(message: String, canResume: Bool)
    case cancelled
}

private enum NearbySyncFlowDirection {
    case send
    case receive
}

private actor NearbySyncBooleanDecision {
    private var buffered: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let buffered {
            self.buffered = nil
            return buffered
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: Bool) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else if buffered == nil {
            buffered = value
        }
    }
}

private final class NearbySyncCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

@MainActor
final class NearbySyncFlowController {
    let events: AsyncStream<NearbySyncFlowEvent>

    private let context: ModelContext
    private let vault: CaptureVaultService
    private let stagingStore: TransferStagingStore
    private let networkFactory: any NearbySyncFlowNetworkFactory
    private let temporaryExportRoot: URL?
    private let onImportCompleted: @MainActor () -> Void
    private let discoveryTimeoutNanoseconds: UInt64
    private let autoConnectDelayNanoseconds: UInt64
    private let continuation: AsyncStream<NearbySyncFlowEvent>.Continuation
    private let cancellationFlag = NearbySyncCancellationFlag()

    private var browser: (any NearbySyncBrowsing)?
    private var listener: (any NearbySyncListening)?
    private var transport: (any NearbyByteTransport)?
    private var senderCoordinator: NearbySyncSenderCoordinator?
    private var receiverCoordinator: NearbySyncReceiverCoordinator?
    private var package: NearbySyncExportPackage?
    private var lastScope: TransferScope?
    private var lastDirection: NearbySyncFlowDirection?
    private var pairingDecision: NearbySyncBooleanDecision?
    private var manifestDecision: NearbySyncBooleanDecision?
    private var browserTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var coordinatorEventTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var discoveryTimeoutTask: Task<Void, Never>?
    private var autoConnectTask: Task<Void, Never>?
    private var currentPeers: [NearbySyncFlowPeer] = []
    private var generation = 0
    private var acceptedInvitation = false
    private var userRejectedDecision = false
    private(set) var isActive = false

    var activeTransferID: UUID? {
        package?.manifest.transferID
    }

    init(
        context: ModelContext,
        vault: CaptureVaultService,
        stagingStore: TransferStagingStore,
        networkFactory: any NearbySyncFlowNetworkFactory =
            ProductionNearbySyncFlowNetworkFactory(),
        temporaryExportRoot: URL? = nil,
        discoveryTimeoutNanoseconds: UInt64 = 30_000_000_000,
        autoConnectDelayNanoseconds: UInt64 = 700_000_000,
        onImportCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.context = context
        self.vault = vault
        self.stagingStore = stagingStore
        self.networkFactory = networkFactory
        self.temporaryExportRoot = temporaryExportRoot
        self.discoveryTimeoutNanoseconds = discoveryTimeoutNanoseconds
        self.autoConnectDelayNanoseconds = autoConnectDelayNanoseconds
        self.onImportCompleted = onImportCompleted
        let pair = AsyncStream.makeStream(
            of: NearbySyncFlowEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    static func production(
        context: ModelContext,
        fileManager: FileManager = .default,
        onImportCompleted: @escaping @MainActor () -> Void = {}
    ) throws -> NearbySyncFlowController {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let stagingRoot = support
            .appendingPathComponent("CareThread", isDirectory: true)
            .appendingPathComponent("NearbyTransferStaging", isDirectory: true)
        return NearbySyncFlowController(
            context: context,
            vault: try CaptureVaultService(fileManager: fileManager),
            stagingStore: try TransferStagingStore(
                rootURL: stagingRoot,
                fileManager: fileManager
            ),
            onImportCompleted: onImportCompleted
        )
    }

    func startSending(scope: TransferScope) async throws {
        guard !isActive else {
            throw TransferProtocolError.invalidStateTransition
        }
        generation += 1
        let currentGeneration = generation
        userRejectedDecision = false
        cancellationFlag.reset()
        lastDirection = .send
        lastScope = scope
        if package == nil {
            package = try NearbySyncExporter(
                context: context,
                vault: vault,
                temporaryRoot: temporaryExportRoot
            ).prepare(scope: scope)
        }
        isActive = true
        try beginBrowsing(generation: currentGeneration)
    }

    func startReceiving() async throws {
        guard !isActive else {
            throw TransferProtocolError.invalidStateTransition
        }
        generation += 1
        let currentGeneration = generation
        userRejectedDecision = false
        cancellationFlag.reset()
        lastDirection = .receive
        isActive = true
        acceptedInvitation = false
        let listener = try networkFactory.makeListener()
        self.listener = listener
        continuation.yield(.waiting(alias: listener.alias))
        listenerTask = Task { [weak self, listener] in
            for await event in listener.events {
                guard let self else { return }
                await self.handleListening(event, generation: currentGeneration)
            }
        }
        scheduleDiscoveryTimeout(generation: currentGeneration)
        listener.start()
    }

    func selectPeer(_ peerID: UUID) async throws {
        guard isActive,
              lastDirection == .send,
              let browser,
              currentPeers.contains(where: { $0.id == peerID }),
              let package else {
            throw TransferProtocolError.invalidStateTransition
        }
        let currentGeneration = generation
        autoConnectTask?.cancel()
        discoveryTimeoutTask?.cancel()
        let transport = try browser.transport(for: peerID)
        browser.cancel()
        browserTask?.cancel()
        browserTask = nil
        self.browser = nil
        self.transport = transport
        let coordinator = try NearbySyncSenderCoordinator(
            transport: transport,
            package: package
        )
        senderCoordinator = coordinator
        let decision = NearbySyncBooleanDecision()
        pairingDecision = decision
        forward(
            coordinator.events,
            generation: currentGeneration
        )
        sessionTask = Task { [weak self, coordinator, decision] in
            do {
                let result = try await coordinator.run { _ in
                    await decision.wait()
                }
                await self?.senderCompleted(
                    result,
                    generation: currentGeneration
                )
            } catch {
                await self?.sessionFailed(error, generation: currentGeneration)
            }
        }
    }

    func confirmPairing(_ accepted: Bool) {
        userRejectedDecision = !accepted
        guard let pairingDecision else { return }
        Task { await pairingDecision.resolve(accepted) }
    }

    func confirmManifest(_ accepted: Bool) {
        userRejectedDecision = !accepted
        guard let manifestDecision else { return }
        Task { await manifestDecision.resolve(accepted) }
    }

    func retry() async throws {
        guard !isActive, let lastDirection else {
            throw TransferProtocolError.invalidStateTransition
        }
        switch lastDirection {
        case .send:
            guard let lastScope else {
                throw TransferProtocolError.invalidStateTransition
            }
            try await startSending(scope: lastScope)
        case .receive:
            try await startReceiving()
        }
    }

    func cancel() async {
        generation += 1
        await releaseSession(cleanExportPackage: true)
        lastScope = nil
        lastDirection = nil
        continuation.yield(.cancelled)
    }

    func handleBackgrounding() async {
        await cancel()
    }

    private func beginBrowsing(generation: Int) throws {
        let browser = try networkFactory.makeBrowser()
        self.browser = browser
        currentPeers = []
        continuation.yield(.discovering(peers: []))
        browserTask = Task { [weak self, browser] in
            for await event in browser.events {
                guard let self else { return }
                await self.handleDiscovery(event, generation: generation)
            }
        }
        scheduleDiscoveryTimeout(generation: generation)
        browser.start()
    }

    private func handleDiscovery(
        _ event: NearbySyncDiscoveryEvent,
        generation eventGeneration: Int
    ) async {
        guard eventGeneration == generation, isActive else { return }
        switch event {
        case .ready:
            continuation.yield(.discovering(peers: currentPeers))
        case let .peers(peers):
            currentPeers = peers.sorted { $0.alias < $1.alias }
            continuation.yield(.discovering(peers: currentPeers))
            autoConnectTask?.cancel()
            if currentPeers.count == 1, let only = currentPeers.first {
                autoConnectTask = Task { [weak self] in
                    do {
                        try await Task.sleep(
                            nanoseconds: self?.autoConnectDelayNanoseconds ?? 0
                        )
                        guard let self,
                              self.generation == eventGeneration,
                              self.currentPeers == [only] else { return }
                        try await self.selectPeer(only.id)
                    } catch is CancellationError {
                        return
                    } catch {
                        await self?.sessionFailed(
                            error,
                            generation: eventGeneration
                        )
                    }
                }
            }
        case let .waiting(reason):
            await sessionFailed(
                TransferProtocolError.transport(reason),
                generation: eventGeneration
            )
        case let .failed(reason):
            await sessionFailed(
                TransferProtocolError.transport(reason),
                generation: eventGeneration
            )
        case .cancelled:
            break
        }
    }

    private func handleListening(
        _ event: NearbySyncListeningEvent,
        generation eventGeneration: Int
    ) async {
        guard eventGeneration == generation, isActive else {
            if case let .invitation(invitation) = event {
                invitation.reject()
            }
            return
        }
        switch event {
        case let .ready(alias):
            continuation.yield(.waiting(alias: alias))
        case let .invitation(invitation):
            guard !acceptedInvitation else {
                invitation.reject()
                return
            }
            acceptedInvitation = true
            discoveryTimeoutTask?.cancel()
            do {
                let transport = try invitation.accept()
                listener?.cancel()
                listenerTask?.cancel()
                listenerTask = nil
                listener = nil
                self.transport = transport
                try startReceiver(
                    transport: transport,
                    generation: eventGeneration
                )
            } catch {
                await sessionFailed(error, generation: eventGeneration)
            }
        case let .waiting(reason):
            await sessionFailed(
                TransferProtocolError.transport(reason),
                generation: eventGeneration
            )
        case let .failed(reason):
            await sessionFailed(
                TransferProtocolError.transport(reason),
                generation: eventGeneration
            )
        case .cancelled:
            break
        }
    }

    private func startReceiver(
        transport: any NearbyByteTransport,
        generation currentGeneration: Int
    ) throws {
        let existingIDs = Set(
            try context.fetch(FetchDescriptor<Patient>()).map(\.id)
        )
        let importer = NearbySyncImporter(
            context: context,
            vault: vault,
            stagingStore: stagingStore
        )
        let coordinator = try NearbySyncReceiverCoordinator(
            transport: transport,
            stagingStore: stagingStore,
            existingPatientIDs: existingIDs,
            importer: importer.commitImporter(
                userConfirmedManifest: { true },
                cancellation: { [cancellationFlag] in
                    Task.isCancelled || cancellationFlag.isCancelled()
                }
            )
        )
        receiverCoordinator = coordinator
        let pair = NearbySyncBooleanDecision()
        let manifest = NearbySyncBooleanDecision()
        pairingDecision = pair
        manifestDecision = manifest
        forward(coordinator.events, generation: currentGeneration)
        sessionTask = Task { [weak self, coordinator, pair, manifest] in
            do {
                let result = try await coordinator.run(
                    confirmPairing: { _ in await pair.wait() },
                    confirmManifest: { _ in await manifest.wait() }
                )
                await self?.receiverCompleted(
                    result,
                    generation: currentGeneration
                )
            } catch {
                await self?.sessionFailed(error, generation: currentGeneration)
            }
        }
    }

    private func forward(
        _ stream: AsyncStream<NearbySyncCoordinatorEvent>,
        generation eventGeneration: Int
    ) {
        coordinatorEventTask?.cancel()
        coordinatorEventTask = Task { [weak self] in
            for await event in stream {
                guard let self,
                      self.generation == eventGeneration,
                      self.isActive else { return }
                self.continuation.yield(.coordinator(event))
            }
        }
    }

    private func senderCompleted(
        _ result: NearbySyncSenderResult,
        generation eventGeneration: Int
    ) async {
        guard eventGeneration == generation, isActive else { return }
        continuation.yield(.completed(resultSHA256: result.resultSHA256))
        await releaseSession(cleanExportPackage: true)
    }

    private func receiverCompleted(
        _ result: NearbySyncImportResult,
        generation eventGeneration: Int
    ) async {
        guard eventGeneration == generation, isActive else { return }
        onImportCompleted()
        continuation.yield(.completed(resultSHA256: result.resultSHA256))
        await releaseSession(cleanExportPackage: false)
    }

    private func sessionFailed(
        _ error: Error,
        generation eventGeneration: Int
    ) async {
        guard eventGeneration == generation, isActive else { return }
        let userRejected = userRejectedDecision
        let message: String
        if userRejected {
            message = "已按你的选择停止迁移，未写入任何资料。"
        } else if let localized = error as? LocalizedError,
                  let description = localized.errorDescription {
            message = description
        } else {
            message = "连接已中断。已保留可校验的迁移进度，可以继续。"
        }
        await releaseSession(cleanExportPackage: userRejected)
        continuation.yield(
            .failed(message: message, canResume: !userRejected)
        )
    }

    private func scheduleDiscoveryTimeout(generation eventGeneration: Int) {
        discoveryTimeoutTask?.cancel()
        guard discoveryTimeoutNanoseconds > 0 else { return }
        discoveryTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: self?.discoveryTimeoutNanoseconds ?? 0
                )
                guard let self,
                      self.generation == eventGeneration,
                      self.isActive,
                      self.currentPeers.isEmpty else { return }
                await self.sessionFailed(
                    TransferProtocolError.timedOut("discovery"),
                    generation: eventGeneration
                )
            } catch {
                return
            }
        }
    }

    private func releaseSession(cleanExportPackage: Bool) async {
        isActive = false
        cancellationFlag.cancel()
        browserTask?.cancel()
        listenerTask?.cancel()
        coordinatorEventTask?.cancel()
        sessionTask?.cancel()
        discoveryTimeoutTask?.cancel()
        autoConnectTask?.cancel()
        browserTask = nil
        listenerTask = nil
        coordinatorEventTask = nil
        sessionTask = nil
        discoveryTimeoutTask = nil
        autoConnectTask = nil
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        transport?.cancel()
        transport = nil
        if let pairingDecision {
            await pairingDecision.resolve(false)
        }
        if let manifestDecision {
            await manifestDecision.resolve(false)
        }
        pairingDecision = nil
        manifestDecision = nil
        if let senderCoordinator {
            await senderCoordinator.cancel()
        }
        if let receiverCoordinator {
            await receiverCoordinator.cancel()
        }
        self.senderCoordinator = nil
        self.receiverCoordinator = nil
        currentPeers = []
        acceptedInvitation = false
        if cleanExportPackage {
            package?.cleanup()
            package = nil
        }
    }

    deinit {
        browserTask?.cancel()
        listenerTask?.cancel()
        coordinatorEventTask?.cancel()
        sessionTask?.cancel()
        discoveryTimeoutTask?.cancel()
        autoConnectTask?.cancel()
        browser?.cancel()
        listener?.cancel()
        transport?.cancel()
        package?.cleanup()
        continuation.finish()
    }
}
