import Foundation
import Network
import Testing
@testable import CareThread

struct NearbyTransferNetworkTests {
    @Test("Network 参数只有 TCP，不伪装 TLS，并禁止蜂窝路径")
    func networkParametersAreLocalTCPOnly() {
        let parameters = NearbyNetworkConfiguration.synchronizationParameters()
        #expect(parameters.includePeerToPeer)
        #expect(
            !parameters.defaultProtocolStack.applicationProtocols.contains {
                $0 is NWProtocolTLS.Options
            }
        )
        #expect(parameters.defaultProtocolStack.transportProtocol is NWProtocolTCP.Options)
        #expect(parameters.prohibitedInterfaceTypes?.contains(.cellular) == true)
    }

    @Test("Bonjour 类型合法且会话名随机，不含成员姓名")
    func discoveryMetadataIsOpaque() {
        let first = NearbyNetworkConfiguration.randomSessionName()
        let second = NearbyNetworkConfiguration.randomSessionName()
        #expect(NearbyNetworkConfiguration.serviceType == "_carethread._tcp")
        #expect(first.hasPrefix("ct-"))
        #expect(first.count == 15)
        #expect(first != second)
        #expect(!first.contains("张三"))
    }

    @Test("Listener 不设置 TXT 业务数据")
    func listenerHasNoDiscoveryInfo() throws {
        let name = "ct-123456789012"
        let listener = try NearbyNetworkConfiguration.listener(sessionName: name)
        #expect(listener.service?.name == name)
        #expect(listener.service?.type == NearbyNetworkConfiguration.serviceType)
        #expect(listener.service?.txtRecord == nil)
        listener.cancel()
    }

    @Test("任意 hostPort 不是受信 CareThread service endpoint")
    func arbitraryHostPortIsRejectedByEndpointPolicy() {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: 9
        )
        #expect(!NearbyNetworkConfiguration.isValidServiceEndpoint(endpoint))
    }

    @Test("可注入内存 transport 双向传帧并观测生命周期")
    func inMemoryTransportIsBidirectional() async throws {
        let (sender, receiver) = InMemoryNearbyByteTransport.makePair()
        var receiverIterator = receiver.incomingFrames.makeAsyncIterator()
        var senderIterator = sender.incomingFrames.makeAsyncIterator()
        var lifecycle = sender.lifecycleEvents.makeAsyncIterator()
        sender.start()
        #expect(await lifecycle.next() == .ready)
        try await sender.send(Data("one".utf8))
        try await receiver.send(Data("two".utf8))
        #expect(await receiverIterator.next() == Data("one".utf8))
        #expect(await senderIterator.next() == Data("two".utf8))
        sender.cancel()
        receiver.cancel()
    }

    @Test("Transport 在发送前拒绝空帧与超限帧")
    func transportRejectsInvalidFrameSizes() async {
        let (sender, receiver) = InMemoryNearbyByteTransport.makePair()
        do {
            try await sender.send(Data())
            Issue.record("Expected empty frame rejection")
        } catch {
            #expect(error as? TransferProtocolError == .limitExceeded("wire frame"))
        }
        do {
            try await sender.send(
                Data(
                    repeating: 0,
                    count: NearbyNetworkConfiguration.maximumWireFrameBytes + 1
                )
            )
            Issue.record("Expected oversized frame rejection")
        } catch {
            #expect(error as? TransferProtocolError == .limitExceeded("wire frame"))
        }
        sender.cancel()
        receiver.cancel()
    }

    @Test("未消费超过 8 帧触发有界背压而非无限占内存")
    func incomingBackpressureIsBounded() async throws {
        let (sender, receiver) = InMemoryNearbyByteTransport.makePair()
        for index in 0..<8 {
            try await sender.send(Data("frame-\(index)".utf8))
        }
        do {
            try await sender.send(Data("overflow".utf8))
            Issue.record("Expected bounded backpressure rejection")
        } catch {
            #expect(
                error as? TransferProtocolError
                    == .transport("peer backpressure limit")
            )
        }
        sender.cancel()
        receiver.cancel()
    }
}
