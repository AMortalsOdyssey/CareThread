import Foundation
import Network
import OSLog

enum NearbyNetworkConfiguration {
    /// Bonjour metadata is a protocol identifier only; no patient/device-owner data.
    static let serviceType = "_carethread._tcp"
    static let maximumWireFrameBytes = TransferLimits.maximumManifestBytes + 4_096
    static let maximumReceiveSegmentBytes = TransferLimits.chunkSize

    static func randomSessionName() -> String {
        "ct-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
    }

    /// Network.framework supplies local Bonjour discovery and TCP transport only.
    /// Confidentiality and peer authentication are owned by NearbyTransferSession.
    static func synchronizationParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.prohibitConstrainedPaths = false
        parameters.prohibitExpensivePaths = false
        parameters.serviceClass = .responsiveData
        return parameters
    }

    static func browser() -> NWBrowser {
        NWBrowser(
            for: .bonjour(type: serviceType, domain: "local."),
            using: synchronizationParameters()
        )
    }

    static func listener(sessionName: String = randomSessionName()) throws -> NWListener {
        guard isValidSessionName(sessionName) else {
            throw TransferProtocolError.transport("invalid Bonjour session name")
        }
        let listener = try NWListener(using: synchronizationParameters())
        listener.service = NWListener.Service(
            name: sessionName,
            type: serviceType,
            domain: "local.",
            txtRecord: nil
        )
        return listener
    }

    static func isValidServiceEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .service(name, type, domain, _) = endpoint else { return false }
        return type == serviceType
            && (domain.isEmpty || domain == "local." || domain == "local")
            && isValidSessionName(name)
    }

    private static func isValidSessionName(_ name: String) -> Bool {
        name.range(
            of: "^ct-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil
    }
}

enum NearbyWireFrameCategory: UInt8, CaseIterable, Sendable {
    case control = 1
    case handshake = 2
    case manifest = 3
    case chunk = 4
    case commitReceipt = 5

    var maximumPayloadBytes: Int {
        switch self {
        case .control, .handshake:
            return TransferLimits.maximumControlFrameBytes
        case .manifest:
            return TransferLimits.maximumManifestBytes + 4_096
        case .chunk:
            return TransferChunkWireCodec.maximumEncodedBytes
        case .commitReceipt:
            return TransferLimits.maximumReceiptFrameBytes
        }
    }
}

struct NearbyWireFrame: Equatable, Sendable {
    let category: NearbyWireFrameCategory
    let payload: Data
}

enum NearbyWireFrameCodec {
    static let headerBytes = 8
    private static let magic: [UInt8] = [0x43, 0x54] // CT
    private static let version: UInt8 = 1

    static func encode(_ frame: NearbyWireFrame) throws -> Data {
        guard !frame.payload.isEmpty,
              frame.payload.count <= frame.category.maximumPayloadBytes else {
            throw TransferProtocolError.limitExceeded("wire \(frame.category)")
        }
        var output = Data(magic)
        output.append(version)
        output.append(frame.category.rawValue)
        var count = UInt32(frame.payload.count).bigEndian
        Swift.withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
        output.append(frame.payload)
        return output
    }
}

/// Incremental parser for arbitrarily split or coalesced TCP segments. It keeps
/// at most one bounded frame in memory and applies a separate limit per message
/// class before allocating the declared payload.
struct IncrementalNearbyWireParser: Sendable {
    private var buffer = Data()
    private var parsedFrameCount = 0
    private var parsedPayloadBytes: Int64 = 0

    mutating func append(_ segment: Data) throws -> [NearbyWireFrame] {
        guard !segment.isEmpty,
              segment.count <= NearbyNetworkConfiguration.maximumReceiveSegmentBytes else {
            throw TransferProtocolError.limitExceeded("wire segment")
        }
        guard buffer.count <= NearbyNetworkConfiguration.maximumWireFrameBytes
            + NearbyWireFrameCodec.headerBytes - segment.count else {
            throw TransferProtocolError.limitExceeded("wire parser memory")
        }
        buffer.append(segment)
        var offset = 0
        var frames: [NearbyWireFrame] = []
        var batchBytes = 0

        while buffer.count - offset >= NearbyWireFrameCodec.headerBytes {
            guard buffer[offset] == 0x43,
                  buffer[offset + 1] == 0x54,
                  buffer[offset + 2] == 1,
                  let category = NearbyWireFrameCategory(
                      rawValue: buffer[offset + 3]
                  ) else {
                throw TransferProtocolError.invalidChunk("wire header")
            }
            let length = buffer[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0,
                  length <= UInt32(category.maximumPayloadBytes) else {
                throw TransferProtocolError.limitExceeded("wire \(category)")
            }
            let packetBytes = NearbyWireFrameCodec.headerBytes + Int(length)
            guard buffer.count - offset >= packetBytes else { break }
            guard parsedFrameCount < TransferLimits.maximumWireFrames else {
                throw TransferProtocolError.limitExceeded("wire frame count")
            }
            let payloadStart = offset + NearbyWireFrameCodec.headerBytes
            let payloadEnd = offset + packetBytes
            let payload = buffer.subdata(in: payloadStart..<payloadEnd)
            batchBytes += payload.count
            guard batchBytes <= NearbyNetworkConfiguration.maximumWireFrameBytes * 2 else {
                throw TransferProtocolError.limitExceeded("wire parser batch")
            }
            frames.append(NearbyWireFrame(category: category, payload: payload))
            parsedFrameCount += 1
            let (total, overflow) = parsedPayloadBytes.addingReportingOverflow(
                Int64(payload.count)
            )
            guard !overflow,
                  total <= TransferLimits.maximumTransferBytes
                      + Int64(TransferLimits.maximumManifestBytes * 2) else {
                throw TransferProtocolError.limitExceeded("wire connection bytes")
            }
            parsedPayloadBytes = total
            offset += packetBytes
        }
        if offset > 0 {
            buffer.removeSubrange(0..<offset)
        }
        return frames
    }

    var bufferedByteCount: Int { buffer.count }
    var frameCount: Int { parsedFrameCount }
}

enum TransferDeadlineOperation: String, Sendable {
    case send
    case handshake
    case stage

    var nanoseconds: UInt64 {
        switch self {
        case .send: return 30_000_000_000
        case .handshake: return 60_000_000_000
        case .stage: return 120_000_000_000
        }
    }
}

enum TransferDeadline {
    static func run<T: Sendable>(
        operation: TransferDeadlineOperation,
        nanoseconds: UInt64? = nil,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let duration = nanoseconds ?? operation.nanoseconds
        guard duration > 0 else {
            throw TransferProtocolError.timedOut(operation.rawValue)
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: duration)
                throw TransferProtocolError.timedOut(operation.rawValue)
            }
            guard let result = try await group.next() else {
                throw TransferProtocolError.cancelled
            }
            group.cancelAll()
            return result
        }
    }
}

struct NearbyDiscoveredPeer: Hashable, Sendable {
    let sessionName: String
    fileprivate let endpoint: NWEndpoint

    init?(result: NWBrowser.Result) {
        guard NearbyNetworkConfiguration.isValidServiceEndpoint(result.endpoint),
              case let .service(name, _, _, _) = result.endpoint else {
            return nil
        }
        sessionName = name
        endpoint = result.endpoint
    }
}

enum NearbyBrowserEvent: Sendable {
    case ready
    case peers(Set<NearbyDiscoveredPeer>)
    case waiting(String)
    case failed(String)
    case cancelled
}

final class NearbyBrowserBridge: @unchecked Sendable {
    let events: AsyncStream<NearbyBrowserEvent>

    private let browser: NWBrowser
    private let continuation: AsyncStream<NearbyBrowserEvent>.Continuation
    private let queue = DispatchQueue(label: "me.multiego.carethread.nearby.browser")
    private let lock = NSLock()
    private var started = false
    private var stopped = false

    init(browser: NWBrowser = NearbyNetworkConfiguration.browser()) {
        self.browser = browser
        let pair = AsyncStream.makeStream(
            of: NearbyBrowserEvent.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        events = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        browser.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = Set(results.compactMap(NearbyDiscoveredPeer.init(result:)))
            self?.yield(.peers(peers))
        }
    }

    func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        NearbyTransferLogger.transport.info("Nearby Bonjour browsing started")
        browser.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        browser.cancel()
        continuation.finish()
    }

    private func yield(_ event: NearbyBrowserEvent) {
        if case .dropped = continuation.yield(event) {
            NearbyTransferLogger.transport.warning("Nearby browser event buffer dropped data")
        }
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .setup:
            break
        case .ready:
            yield(.ready)
        case let .waiting(error):
            yield(.waiting(String(describing: error)))
        case let .failed(error):
            NearbyTransferLogger.transport.error(
                "Nearby browser failed: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            yield(.failed(String(describing: error)))
            continuation.finish()
        case .cancelled:
            yield(.cancelled)
            continuation.finish()
        @unknown default:
            yield(.failed("unknown browser state"))
            continuation.finish()
        }
    }
}

final class NearbyConnectionInvitation: @unchecked Sendable {
    fileprivate let connection: NWConnection
    fileprivate let lease: NearbyAdmissionLease
    private let lock = NSLock()
    private var claimed = false

    fileprivate init(connection: NWConnection, lease: NearbyAdmissionLease) {
        self.connection = connection
        self.lease = lease
    }

    fileprivate func claim() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else {
            throw TransferProtocolError.transport("invitation already claimed")
        }
        claimed = true
    }

    func reject() {
        connection.cancel()
        lease.release()
    }
}

enum NearbyListenerEvent: Sendable {
    case ready
    case invitation(NearbyConnectionInvitation)
    case waiting(String)
    case failed(String)
    case cancelled
}

final class NearbyListenerBridge: @unchecked Sendable {
    let sessionName: String
    let events: AsyncStream<NearbyListenerEvent>

    private let listener: NWListener
    private let continuation: AsyncStream<NearbyListenerEvent>.Continuation
    private let admission = NearbyAdmissionController()
    private let queue = DispatchQueue(label: "me.multiego.carethread.nearby.listener")
    private let lock = NSLock()
    private var started = false
    private var stopped = false

    init(sessionName: String = NearbyNetworkConfiguration.randomSessionName()) throws {
        self.sessionName = sessionName
        listener = try NearbyNetworkConfiguration.listener(sessionName: sessionName)
        let pair = AsyncStream.makeStream(
            of: NearbyListenerEvent.self,
            bufferingPolicy: .bufferingOldest(4)
        )
        events = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in self?.cancel() }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self, let lease = admission.admit() else {
                connection.cancel()
                return
            }
            let invitation = NearbyConnectionInvitation(connection: connection, lease: lease)
            if case .dropped = continuation.yield(.invitation(invitation)) {
                invitation.reject()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
    }

    func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        NearbyTransferLogger.transport.info("Nearby Bonjour listener started")
        listener.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        listener.cancel()
        continuation.finish()
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .setup:
            break
        case .ready:
            continuation.yield(.ready)
        case let .waiting(error):
            continuation.yield(.waiting(String(describing: error)))
        case let .failed(error):
            NearbyTransferLogger.transport.error(
                "Nearby listener failed: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            continuation.yield(.failed(String(describing: error)))
            continuation.finish()
        case .cancelled:
            continuation.yield(.cancelled)
            continuation.finish()
        @unknown default:
            continuation.yield(.failed("unknown listener state"))
            continuation.finish()
        }
    }
}

enum NearbyTransportLifecycleEvent: Sendable, Equatable {
    case ready
    case waiting(String)
    case failed(String)
    case remoteClosed
    case cancelled
}

protocol NearbyByteTransport: Sendable {
    var incomingFrames: AsyncStream<Data> { get }
    var lifecycleEvents: AsyncStream<NearbyTransportLifecycleEvent> { get }
    func start()
    func send(_ frame: Data) async throws
    func send(_ frame: Data, category: NearbyWireFrameCategory) async throws
    func cancel()
}

extension NearbyByteTransport {
    func send(_ frame: Data) async throws {
        try await send(frame, category: .control)
    }
}

final class NetworkNearbyByteTransport: NearbyByteTransport, @unchecked Sendable {
    let incomingFrames: AsyncStream<Data>
    let lifecycleEvents: AsyncStream<NearbyTransportLifecycleEvent>

    private let connection: NWConnection
    private let admissionLease: NearbyAdmissionLease?
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let lifecycleContinuation: AsyncStream<NearbyTransportLifecycleEvent>.Continuation
    private let sendGate = BoundedSendGate(maximumWaiters: 8)
    private let queue = DispatchQueue(label: "me.multiego.carethread.nearby.connection")
    private let lock = NSLock()
    private var wireParser = IncrementalNearbyWireParser()
    private var started = false
    private var stopped = false

    /// Production outbound connections can only use an opaque peer emitted by
    /// this app's strict Bonjour browser.
    init(peer: NearbyDiscoveredPeer) throws {
        guard NearbyNetworkConfiguration.isValidServiceEndpoint(peer.endpoint) else {
            throw TransferProtocolError.transport("untrusted endpoint")
        }
        connection = NWConnection(
            to: peer.endpoint,
            using: NearbyNetworkConfiguration.synchronizationParameters()
        )
        admissionLease = nil
        let streams = Self.makeStreams()
        incomingFrames = streams.frames.stream
        incomingContinuation = streams.frames.continuation
        lifecycleEvents = streams.events.stream
        lifecycleContinuation = streams.events.continuation
        configureHandlers()
    }

    /// Production inbound connections require the single-use capability emitted
    /// by the rate-limited CareThread listener.
    init(invitation: NearbyConnectionInvitation) throws {
        try invitation.claim()
        connection = invitation.connection
        admissionLease = invitation.lease
        let streams = Self.makeStreams()
        incomingFrames = streams.frames.stream
        incomingContinuation = streams.frames.continuation
        lifecycleEvents = streams.events.stream
        lifecycleContinuation = streams.events.continuation
        configureHandlers()
    }

    func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ frame: Data, category: NearbyWireFrameCategory) async throws {
        guard !frame.isEmpty,
              frame.count <= category.maximumPayloadBytes else {
            throw TransferProtocolError.limitExceeded("wire frame")
        }
        try await sendGate.acquire()
        do {
            try checkRunning()
            let packet = try NearbyWireFrameCodec.encode(
                NearbyWireFrame(category: category, payload: frame)
            )
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: packet,
                    contentContext: .defaultStream,
                    isComplete: false,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(
                                throwing: TransferProtocolError.transport(
                                    String(describing: error)
                                )
                            )
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
            await sendGate.release()
        } catch {
            await sendGate.release()
            throw error
        }
    }

    func cancel() {
        finish(.cancelled, cancelConnection: true)
    }

    private static func makeStreams() -> (
        frames: (
            stream: AsyncStream<Data>,
            continuation: AsyncStream<Data>.Continuation
        ),
        events: (
            stream: AsyncStream<NearbyTransportLifecycleEvent>,
            continuation: AsyncStream<NearbyTransportLifecycleEvent>.Continuation
        )
    ) {
        let frames = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(8)
        )
        let events = AsyncStream.makeStream(
            of: NearbyTransportLifecycleEvent.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        return (frames, events)
    }

    private func configureHandlers() {
        incomingContinuation.onTermination = { [weak self] _ in self?.cancel() }
        lifecycleContinuation.onTermination = { [weak self] _ in self?.cancel() }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                lifecycleContinuation.yield(.ready)
            case let .waiting(error):
                lifecycleContinuation.yield(.waiting(String(describing: error)))
            case let .failed(error):
                NearbyTransferLogger.transport.error(
                    "Nearby TCP connection failed: \(String(describing: error), privacy: .private(mask: .hash))"
                )
                finish(.failed(String(describing: error)), cancelConnection: true)
            case .cancelled:
                finish(.cancelled, cancelConnection: false)
            default:
                break
            }
        }
    }

    private func checkRunning() throws {
        lock.lock()
        defer { lock.unlock() }
        guard started, !stopped else { throw TransferProtocolError.cancelled }
    }

    private func receiveNext() {
        lock.lock()
        let shouldReceive = started && !stopped
        lock.unlock()
        guard shouldReceive else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: NearbyNetworkConfiguration.maximumReceiveSegmentBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                consume(data)
            }
            if let error {
                finish(.failed(String(describing: error)), cancelConnection: true)
            } else if isComplete {
                finish(.remoteClosed, cancelConnection: true)
            } else {
                receiveNext()
            }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        let parsed: [NearbyWireFrame]
        do {
            parsed = try wireParser.append(data)
        } catch {
            lock.unlock()
            finish(.failed(String(describing: error)), cancelConnection: true)
            return
        }
        lock.unlock()

        for frame in parsed {
            if case .dropped = incomingContinuation.yield(frame.payload) {
                finish(.failed("incoming backpressure limit"), cancelConnection: true)
                return
            }
        }
    }

    private func finish(
        _ event: NearbyTransportLifecycleEvent,
        cancelConnection: Bool
    ) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        lifecycleContinuation.yield(event)
        incomingContinuation.finish()
        lifecycleContinuation.finish()
        admissionLease?.release()
        if cancelConnection {
            connection.cancel()
        }
    }
}

final class InMemoryNearbyByteTransport: NearbyByteTransport, @unchecked Sendable {
    let incomingFrames: AsyncStream<Data>
    let lifecycleEvents: AsyncStream<NearbyTransportLifecycleEvent>

    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let lifecycleContinuation: AsyncStream<NearbyTransportLifecycleEvent>.Continuation
    private let lock = NSLock()
    private weak var peer: InMemoryNearbyByteTransport?
    private var stopped = false

    private init() {
        let frames = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(8)
        )
        incomingFrames = frames.stream
        incomingContinuation = frames.continuation
        let events = AsyncStream.makeStream(
            of: NearbyTransportLifecycleEvent.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        lifecycleEvents = events.stream
        lifecycleContinuation = events.continuation
    }

    static func makePair() -> (InMemoryNearbyByteTransport, InMemoryNearbyByteTransport) {
        let first = InMemoryNearbyByteTransport()
        let second = InMemoryNearbyByteTransport()
        first.peer = second
        second.peer = first
        return (first, second)
    }

    func start() {
        lifecycleContinuation.yield(.ready)
    }

    func send(_ frame: Data, category: NearbyWireFrameCategory) async throws {
        guard !frame.isEmpty,
              frame.count <= category.maximumPayloadBytes else {
            throw TransferProtocolError.limitExceeded("wire frame")
        }
        let destination: InMemoryNearbyByteTransport
        let (isStopped, candidate) = sendState()
        guard !isStopped, let candidate else {
            throw TransferProtocolError.cancelled
        }
        destination = candidate
        if case .dropped = destination.incomingContinuation.yield(frame) {
            destination.finish(.failed("incoming backpressure limit"))
            throw TransferProtocolError.transport("peer backpressure limit")
        }
    }

    private func sendState() -> (Bool, InMemoryNearbyByteTransport?) {
        lock.lock()
        defer { lock.unlock() }
        return (stopped, peer)
    }

    func cancel() {
        finish(.cancelled)
    }

    private func finish(_ event: NearbyTransportLifecycleEvent) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        lifecycleContinuation.yield(event)
        incomingContinuation.finish()
        lifecycleContinuation.finish()
    }
}

private actor BoundedSendGate {
    private let maximumWaiters: Int
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maximumWaiters: Int) {
        self.maximumWaiters = maximumWaiters
    }

    func acquire() async throws {
        if !busy {
            busy = true
            return
        }
        guard waiters.count < maximumWaiters else {
            throw TransferProtocolError.transport("send backpressure limit")
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class NearbyAdmissionController: @unchecked Sendable {
    private let lock = NSLock()
    private var recentAdmissions: [Date] = []
    private var activeCount = 0
    private let maximumActive = 3
    private let maximumPerMinute = 8

    func admit(now: Date = Date()) -> NearbyAdmissionLease? {
        lock.lock()
        defer { lock.unlock() }
        recentAdmissions.removeAll { now.timeIntervalSince($0) > 60 }
        guard activeCount < maximumActive,
              recentAdmissions.count < maximumPerMinute else {
            return nil
        }
        activeCount += 1
        recentAdmissions.append(now)
        return NearbyAdmissionLease { [weak self] in self?.release() }
    }

    private func release() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        lock.unlock()
    }
}

final class NearbyAdmissionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseHandler: (() -> Void)?

    fileprivate init(releaseHandler: @escaping () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func release() {
        lock.lock()
        let handler = releaseHandler
        releaseHandler = nil
        lock.unlock()
        handler?()
    }

    deinit {
        release()
    }
}

private enum NearbyTransferLogger {
    static let transport = Logger(
        subsystem: "me.multiego.carethread",
        category: "nearby-transfer"
    )
}
