import Foundation
import SwiftData
import Testing
@testable import CareThread

private final class FlowTestBrowser: NearbySyncBrowsing, @unchecked Sendable {
    let events: AsyncStream<NearbySyncDiscoveryEvent>
    private let continuation: AsyncStream<NearbySyncDiscoveryEvent>.Continuation
    private let lock = NSLock()
    private var transports: [UUID: any NearbyByteTransport] = [:]
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var transportRequestCount = 0

    init() {
        let pair = AsyncStream.makeStream(
            of: NearbySyncDiscoveryEvent.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func start() {
        lock.lock()
        startCount += 1
        lock.unlock()
        continuation.yield(.ready)
    }

    func transport(for peerID: UUID) throws -> any NearbyByteTransport {
        lock.lock()
        transportRequestCount += 1
        let result = transports[peerID]
        lock.unlock()
        guard let result else {
            throw TransferProtocolError.transport("test peer missing")
        }
        return result
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }

    func emit(_ event: NearbySyncDiscoveryEvent) {
        continuation.yield(event)
    }

    func setTransport(_ transport: any NearbyByteTransport, for peerID: UUID) {
        lock.lock()
        transports[peerID] = transport
        lock.unlock()
    }
}

private final class FlowTestListener: NearbySyncListening, @unchecked Sendable {
    let alias: String
    let events: AsyncStream<NearbySyncListeningEvent>
    private let continuation: AsyncStream<NearbySyncListeningEvent>.Continuation
    private let lock = NSLock()
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(alias: String = "ct-abcdef123456") {
        self.alias = alias
        let pair = AsyncStream.makeStream(
            of: NearbySyncListeningEvent.self,
            bufferingPolicy: .bufferingOldest(16)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func start() {
        lock.lock()
        startCount += 1
        lock.unlock()
        continuation.yield(.ready(alias: alias))
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }

    func emit(_ event: NearbySyncListeningEvent) {
        continuation.yield(event)
    }
}

private final class FlowTestNetworkFactory: NearbySyncFlowNetworkFactory,
    @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [FlowTestBrowser]
    private var listeners: [FlowTestListener]

    init(
        browsers: [FlowTestBrowser] = [],
        listeners: [FlowTestListener] = []
    ) {
        self.browsers = browsers
        self.listeners = listeners
    }

    func makeBrowser() throws -> any NearbySyncBrowsing {
        lock.lock()
        defer { lock.unlock() }
        guard !browsers.isEmpty else {
            throw TransferProtocolError.transport("no test browser")
        }
        return browsers.removeFirst()
    }

    func makeListener() throws -> any NearbySyncListening {
        lock.lock()
        defer { lock.unlock() }
        guard !listeners.isEmpty else {
            throw TransferProtocolError.transport("no test listener")
        }
        return listeners.removeFirst()
    }
}

@MainActor
private final class FlowEventState {
    var peers: [NearbySyncFlowPeer] = []
    var waitingAlias: String?
    var pairingCode: String?
    var manifestCount = 0
    var progressCount = 0
    var completedSHA: String?
    var failure: (message: String, canResume: Bool)?
    var cancelled = false

    func consume(_ event: NearbySyncFlowEvent) {
        switch event {
        case let .discovering(peers):
            self.peers = peers
        case let .waiting(alias):
            waitingAlias = alias
        case let .coordinator(event):
            switch event {
            case let .pairingCode(_, code):
                pairingCode = code
            case .manifestPreview:
                manifestCount += 1
            case .progress:
                progressCount += 1
            case .state, .result:
                break
            }
        case let .completed(resultSHA256):
            completedSHA = resultSHA256
        case let .failed(message, canResume):
            failure = (message, canResume)
        case .cancelled:
            cancelled = true
        }
    }
}

@MainActor
private func observeFlow(
    _ controller: NearbySyncFlowController,
    state: FlowEventState,
    pairing: Bool? = nil,
    manifest: Bool? = nil
) -> Task<Void, Never> {
    Task {
        for await event in controller.events {
            state.consume(event)
            if case .coordinator(.pairingCode) = event, let pairing {
                controller.confirmPairing(pairing)
            }
            if case .coordinator(.manifestPreview) = event, let manifest {
                controller.confirmManifest(manifest)
            }
        }
    }
}

@MainActor
private func flowEventually(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ condition: @escaping @MainActor () throws -> Bool
) async rethrows -> Bool {
    let step: UInt64 = 20_000_000
    var elapsed: UInt64 = 0
    while elapsed < timeoutNanoseconds {
        if try condition() { return true }
        try? await Task.sleep(nanoseconds: step)
        elapsed += step
    }
    return try condition()
}

@MainActor
private func makeFlowController(
    environment: NearbySyncTestEnvironment,
    factory: FlowTestNetworkFactory,
    refresh: @escaping @MainActor () -> Void = {},
    timeout: UInt64 = 3_000_000_000,
    autoConnectDelay: UInt64 = 60_000_000_000
) throws -> NearbySyncFlowController {
    try NearbySyncFlowController(
        context: environment.context,
        vault: environment.vault,
        stagingStore: TransferStagingStore(
            rootURL: environment.root.appendingPathComponent("FlowStaging"),
            minimumFreeSpaceBytes: 0
        ),
        networkFactory: factory,
        temporaryExportRoot: environment.root.appendingPathComponent("FlowExport"),
        discoveryTimeoutNanoseconds: timeout,
        autoConnectDelayNanoseconds: autoConnectDelay,
        onImportCompleted: refresh
    )
}

private final class FlowRefreshBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class FlowInvitationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var accepted = 0
    private(set) var rejected = 0

    func accept() {
        lock.lock()
        accepted += 1
        lock.unlock()
    }

    func reject() {
        lock.lock()
        rejected += 1
        lock.unlock()
    }
}

@Suite("NearbySync production flow")
struct NearbySyncFlowControllerTests {
    @Test("sender starts Bonjour discovery with no patient identity")
    @MainActor
    func senderStartsDiscovery() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 201)
        let browser = FlowTestBrowser()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser])
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }

        try await controller.startSending(scope: .singlePatient(ids.patientID))
        #expect(await flowEventually { browser.startCount == 1 })
        #expect(state.peers.isEmpty)
        #expect(controller.activeTransferID != nil)
        await controller.cancel()
    }

    @Test("multiple peers are shown and never selected implicitly")
    @MainActor
    func multiplePeersRequireSelection() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 202)
        let browser = FlowTestBrowser()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser]),
            autoConnectDelay: 30_000_000
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        let peers = [
            NearbySyncFlowPeer(id: UUID(), alias: "ct-000000000001"),
            NearbySyncFlowPeer(id: UUID(), alias: "ct-000000000002")
        ]
        browser.emit(.peers(peers))
        #expect(await flowEventually { state.peers.count == 2 })
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(browser.transportRequestCount == 0)
        await controller.cancel()
    }

    @Test("explicit peer selection creates the real byte transport path")
    @MainActor
    func explicitPeerSelection() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 203)
        let browser = FlowTestBrowser()
        let (senderTransport, _) = InMemoryNearbyByteTransport.makePair()
        let peer = NearbySyncFlowPeer(id: UUID(), alias: "ct-000000000003")
        browser.setTransport(senderTransport, for: peer.id)
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser])
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        browser.emit(.peers([peer]))
        #expect(await flowEventually { state.peers == [peer] })
        try await controller.selectPeer(peer.id)
        #expect(browser.transportRequestCount == 1)
        #expect(browser.cancelCount >= 1)
        await controller.cancel()
    }

    @Test("zero-peer cancellation releases discovery and package")
    @MainActor
    func zeroPeerCancellation() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 204)
        let browser = FlowTestBrowser()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser])
        )
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        await controller.cancel()
        #expect(!controller.isActive)
        #expect(controller.activeTransferID == nil)
        #expect(browser.cancelCount >= 1)
    }

    @Test("only one flow session can exist at a time")
    @MainActor
    func onlyOneSession() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 205)
        let browser = FlowTestBrowser()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser])
        )
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        await #expect(throws: TransferProtocolError.self) {
            try await controller.startSending(scope: .singlePatient(ids.patientID))
        }
        await controller.cancel()
    }

    @Test("browser permission failure becomes recoverable")
    @MainActor
    func browserFailureIsRecoverable() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 206)
        let browser = FlowTestBrowser()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser])
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        browser.emit(.waiting("local network denied"))
        #expect(await flowEventually { state.failure?.canResume == true })
        #expect(!controller.isActive)
        #expect(controller.activeTransferID != nil)
        await controller.cancel()
    }

    @Test("discovery timeout keeps the resumable transfer identifier")
    @MainActor
    func discoveryTimeoutRetainsTransfer() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 207)
        let first = FlowTestBrowser()
        let second = FlowTestBrowser()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [first, second]),
            timeout: 40_000_000
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        let transferID = try #require(controller.activeTransferID)
        #expect(await flowEventually { state.failure?.canResume == true })
        try await controller.retry()
        #expect(controller.activeTransferID == transferID)
        #expect(second.startCount == 1)
        await controller.cancel()
    }

    @Test("transport disconnection retries with the same resumable transfer")
    @MainActor
    func transportDisconnectionRetainsTransfer() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 210)
        let first = FlowTestBrowser()
        let second = FlowTestBrowser()
        let (transport, _) = InMemoryNearbyByteTransport.makePair()
        let peer = NearbySyncFlowPeer(
            id: UUID(),
            alias: "ct-000000000010"
        )
        first.setTransport(transport, for: peer.id)
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [first, second]),
            timeout: 10_000_000_000
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        let transferID = try #require(controller.activeTransferID)
        first.emit(.peers([peer]))
        #expect(await flowEventually { state.peers == [peer] })
        try await controller.selectPeer(peer.id)
        transport.cancel()
        #expect(await flowEventually { state.failure?.canResume == true })
        try await controller.retry()
        #expect(controller.activeTransferID == transferID)
        #expect(second.startCount == 1)
        await controller.cancel()
    }

    @Test("backgrounding performs the same complete cleanup as dismiss")
    @MainActor
    func backgroundCleanup() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 208)
        let browser = FlowTestBrowser()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser])
        )
        try await controller.startSending(scope: .singlePatient(ids.patientID))
        await controller.handleBackgrounding()
        #expect(!controller.isActive)
        #expect(controller.activeTransferID == nil)
        #expect(browser.cancelCount >= 1)
    }

    @Test("receiver advertises only a random CareThread alias")
    @MainActor
    func receiverAdvertisesRandomAlias() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let listener = FlowTestListener(alias: "ct-fedcba654321")
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(listeners: [listener])
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }
        try await controller.startReceiving()
        #expect(await flowEventually {
            state.waitingAlias == "ct-fedcba654321"
        })
        #expect(!state.waitingAlias!.contains("虚构"))
        await controller.cancel()
    }

    @Test("an invitation capability is single-use")
    func invitationIsSingleUse() throws {
        let probe = FlowInvitationProbe()
        let (transport, _) = InMemoryNearbyByteTransport.makePair()
        let invitation = NearbySyncFlowInvitation(
            accept: {
                probe.accept()
                return transport
            },
            reject: { probe.reject() }
        )
        _ = try invitation.accept()
        #expect(throws: TransferProtocolError.self) {
            _ = try invitation.accept()
        }
        invitation.reject()
        #expect(probe.accepted == 1)
        #expect(probe.rejected == 0)
    }

    @Test("receiver listener failure is recoverable")
    @MainActor
    func listenerFailureIsRecoverable() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let listener = FlowTestListener()
        let controller = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(listeners: [listener])
        )
        let state = FlowEventState()
        let observer = observeFlow(controller, state: state)
        defer { observer.cancel() }
        try await controller.startReceiving()
        listener.emit(.failed("permission denied"))
        #expect(await flowEventually { state.failure?.canResume == true })
        #expect(!controller.isActive)
        await controller.cancel()
    }

    @Test("view model maps anonymous device selection")
    @MainActor
    func viewModelMapsPeers() {
        let model = NearbySyncViewModel(
            members: [],
            startSend: { _ in },
            startReceive: {},
            pairingDecision: { _ in },
            manifestDecision: { _ in },
            cancel: {},
            resume: {},
            selectPeer: { _ in }
        )
        let peer = NearbySyncFlowPeer(
            id: UUID(),
            alias: "ct-111111111111"
        )
        model.consume(.discovering(peers: [peer]))
        #expect(model.discoveredPeers == [peer])
        #expect(model.phase == .discovering)
    }

    @Test("pair rejection commits no data")
    @MainActor
    func pairRejectionIsAtomic() async throws {
        let result = try await runFlowPair(
            seedCount: 1,
            senderPairing: true,
            receiverPairing: false,
            receiverManifest: true
        )
        #expect(result.receiverPatientCount == 0)
        #expect(result.receiverCompleted == false)
        await result.cancel()
    }

    @Test("manifest rejection commits no data")
    @MainActor
    func manifestRejectionIsAtomic() async throws {
        let result = try await runFlowPair(
            seedCount: 1,
            senderPairing: true,
            receiverPairing: true,
            receiverManifest: false
        )
        #expect(result.receiverPatientCount == 0)
        #expect(result.receiverManifestSeen)
        await result.cancel()
    }

    @Test("single-member flow transfers through actual coordinators")
    @MainActor
    func singleMemberFlowCompletes() async throws {
        let result = try await runFlowPair(seedCount: 1)
        #expect(result.receiverPatientCount == 1)
        #expect(result.senderCompleted)
        #expect(result.receiverCompleted)
        #expect(result.senderProgressCount > 0)
        #expect(result.receiverProgressCount > 0)
        await result.cancel()
    }

    @Test("all-member flow preserves both isolated members")
    @MainActor
    func allMemberFlowCompletes() async throws {
        let result = try await runFlowPair(seedCount: 2)
        #expect(result.receiverPatientCount == 2)
        #expect(result.receiverRecordCount == 2)
        #expect(result.receiverCompleted)
        await result.cancel()
    }

    @Test("successful receive invokes the refresh callback exactly once")
    @MainActor
    func refreshCallbackRunsOnce() async throws {
        let refresh = FlowRefreshBox()
        let result = try await runFlowPair(
            seedCount: 1,
            refresh: { refresh.increment() }
        )
        #expect(result.receiverCompleted)
        #expect(refresh.count == 1)
        await result.cancel()
    }

    @Test("controller releases without a retained task cycle")
    @MainActor
    func controllerDeinitializes() async throws {
        let environment = try NearbySyncTestEnvironment.make()
        let ids = try environment.seedFullGraph(index: 209)
        let browser = FlowTestBrowser()
        var controller: NearbySyncFlowController? = try makeFlowController(
            environment: environment,
            factory: FlowTestNetworkFactory(browsers: [browser])
        )
        weak var weakController = controller
        try await controller?.startSending(scope: .singlePatient(ids.patientID))
        await controller?.cancel()
        controller = nil
        #expect(await flowEventually { weakController == nil })
    }
}

@MainActor
private struct FlowPairResult {
    let sender: NearbySyncFlowController
    let receiver: NearbySyncFlowController
    let senderState: FlowEventState
    let receiverState: FlowEventState
    let senderObserver: Task<Void, Never>
    let receiverObserver: Task<Void, Never>
    let receiverPatientCount: Int
    let receiverRecordCount: Int

    var senderCompleted: Bool { senderState.completedSHA != nil }
    var receiverCompleted: Bool { receiverState.completedSHA != nil }
    var receiverManifestSeen: Bool { receiverState.manifestCount > 0 }
    var senderProgressCount: Int { senderState.progressCount }
    var receiverProgressCount: Int { receiverState.progressCount }

    func cancel() async {
        senderObserver.cancel()
        receiverObserver.cancel()
        await sender.cancel()
        await receiver.cancel()
    }
}

@MainActor
private func runFlowPair(
    seedCount: Int,
    senderPairing: Bool = true,
    receiverPairing: Bool = true,
    receiverManifest: Bool = true,
    refresh: @escaping @MainActor () -> Void = {}
) async throws -> FlowPairResult {
    let senderEnvironment = try NearbySyncTestEnvironment.make()
    let receiverEnvironment = try NearbySyncTestEnvironment.make()
    var firstPatientID: UUID?
    for index in 0..<seedCount {
        let ids = try senderEnvironment.seedFullGraph(index: 300 + index)
        firstPatientID = firstPatientID ?? ids.patientID
    }
    let (senderTransport, receiverTransport) =
        InMemoryNearbyByteTransport.makePair()
    let peer = NearbySyncFlowPeer(
        id: UUID(),
        alias: "ct-222222222222"
    )
    let browser = FlowTestBrowser()
    browser.setTransport(senderTransport, for: peer.id)
    let listener = FlowTestListener(alias: peer.alias)
    let sender = try makeFlowController(
        environment: senderEnvironment,
        factory: FlowTestNetworkFactory(browsers: [browser]),
        timeout: 10_000_000_000
    )
    let receiver = try makeFlowController(
        environment: receiverEnvironment,
        factory: FlowTestNetworkFactory(listeners: [listener]),
        refresh: refresh,
        timeout: 10_000_000_000
    )
    let senderState = FlowEventState()
    let receiverState = FlowEventState()
    let senderObserver = observeFlow(
        sender,
        state: senderState,
        pairing: senderPairing
    )
    let receiverObserver = observeFlow(
        receiver,
        state: receiverState,
        pairing: receiverPairing,
        manifest: receiverManifest
    )
    try await receiver.startReceiving()
    listener.emit(
        .invitation(
            NearbySyncFlowInvitation(
                accept: { receiverTransport },
                reject: { receiverTransport.cancel() }
            )
        )
    )
    let scope: TransferScope
    if seedCount == 1 {
        scope = .singlePatient(try #require(firstPatientID))
    } else {
        scope = .allPatients
    }
    try await sender.startSending(scope: scope)
    browser.emit(.peers([peer]))
    #expect(await flowEventually { senderState.peers == [peer] })
    try await sender.selectPeer(peer.id)

    if receiverPairing && receiverManifest {
        #expect(await flowEventually(
            timeoutNanoseconds: 10_000_000_000
        ) {
            senderState.completedSHA != nil
                && receiverState.completedSHA != nil
        })
    } else {
        #expect(await flowEventually(
            timeoutNanoseconds: 5_000_000_000
        ) {
            senderState.failure != nil || receiverState.failure != nil
        })
    }
    return FlowPairResult(
        sender: sender,
        receiver: receiver,
        senderState: senderState,
        receiverState: receiverState,
        senderObserver: senderObserver,
        receiverObserver: receiverObserver,
        receiverPatientCount: try receiverEnvironment.context.fetchCount(
            FetchDescriptor<Patient>()
        ),
        receiverRecordCount: try receiverEnvironment.context.fetchCount(
            FetchDescriptor<MedicalRecord>()
        )
    )
}
