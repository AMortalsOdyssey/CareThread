import CryptoKit
import Foundation
import Testing
@testable import CareThread

struct NearbyTransferCryptoTests {
    @Test("P256 双端完成 SAS 与 key-confirmation 后才授权敏感帧")
    func fullPairingAuthorizesBothSides() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        #expect(await sessions.sender.isAuthorizedForSensitiveFrames())
        #expect(await sessions.receiver.isAuthorizedForSensitiveFrames())
        #expect(
            keyData(try await sessions.sender.outgoingChunkKey())
                == keyData(try await sessions.receiver.incomingChunkKey())
        )
        #expect(
            keyData(try await sessions.sender.outgoingChunkKey())
                != keyData(try await sessions.sender.incomingChunkKey())
        )
    }

    @Test("SAS 双端确认前拒绝清单与数据密钥")
    func sensitiveMaterialIsBlockedBeforeSAS() async throws {
        let fixture = TransferTestFixture.single()
        let session = try NearbyTransferSession(
            role: .sender,
            transferID: fixture.manifest.transferID
        )
        await #expect(throws: TransferProtocolError.pairingNotConfirmed) {
            _ = try await session.outgoingChunkKey()
        }
        await #expect(throws: TransferProtocolError.pairingNotConfirmed) {
            _ = try await session.sealOutgoingManifest(fixture.manifest)
        }
    }

    @Test("篡改 key-confirmation MAC 被拒绝")
    func tamperedKeyConfirmationIsRejected() async throws {
        let transferID = UUID()
        let sessionID = UUID()
        let sender = try makeSession(
            role: .sender,
            sessionID: sessionID,
            transferID: transferID,
            privateValue: 1,
            nonce: 0x11
        )
        let receiver = try makeSession(
            role: .receiver,
            sessionID: sessionID,
            transferID: transferID,
            privateValue: 2,
            nonce: 0x22
        )
        try await sender.receivePeerHello(receiver.localHello())
        try await receiver.receivePeerHello(sender.localHello())
        let confirmation = try await receiver.confirmPairing(codeMatches: true)
        var tag = confirmation.authenticationTag
        tag[0] ^= 0xFF
        let tampered = TransferKeyConfirmation(
            role: confirmation.role,
            sessionID: confirmation.sessionID,
            transferID: confirmation.transferID,
            keyEpoch: confirmation.keyEpoch,
            transcriptSHA256: confirmation.transcriptSHA256,
            authenticationTag: tag
        )
        await #expect(throws: TransferProtocolError.keyConfirmationFailed) {
            try await sender.receivePeerKeyConfirmation(tampered)
        }
    }

    @Test("sessionID、transferID、角色与 epoch 都绑定 transcript")
    func mismatchedHelloIsRejected() async throws {
        let sender = try NearbyTransferSession(role: .sender, transferID: UUID())
        let other = try NearbyTransferSession(role: .receiver, transferID: UUID())
        await #expect(throws: TransferProtocolError.invalidManifest("session hello mismatch")) {
            try await sender.receivePeerHello(other.localHello())
        }
    }

    @Test("重连产生新 epoch、新密钥并清除授权")
    func reconnectRequiresFreshPairing() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let oldKey = keyData(try await sessions.sender.outgoingChunkKey())
        let hello = try await sessions.sender.beginNewKeyEpoch()
        #expect(hello.keyEpoch == 1)
        #expect(!(await sessions.sender.isAuthorizedForSensitiveFrames()))
        await #expect(throws: TransferProtocolError.pairingNotConfirmed) {
            _ = try await sessions.sender.outgoingChunkKey()
        }
        #expect(!oldKey.isEmpty)
    }

    @Test("认证清单经过严格解码后往返")
    func sealedManifestVerifies() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        #expect(
            try await sessions.receiver.openIncomingManifest(sealed) == fixture.manifest
        )
    }

    @Test("修改清单摘要立即拒绝")
    func tamperedManifestDigestIsRejected() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        let tampered = SealedTransferManifest(
            aad: sealed.aad,
            nonce: sealed.nonce,
            manifestBytes: sealed.manifestBytes,
            manifestSHA256: String(repeating: "0", count: 64),
            authenticationTag: sealed.authenticationTag
        )
        await #expect(throws: TransferProtocolError.manifestIntegrityFailed) {
            _ = try await sessions.receiver.openIncomingManifest(tampered)
        }
    }

    @Test("Chunk header 是认证数据，改变 offset 会失败")
    func chunkAADTamperIsRejected() throws {
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        let header = TransferChunkHeader(
            transferID: UUID(),
            fileID: UUID(),
            sequence: 0,
            offset: 0,
            plaintextCount: 5,
            isFinal: true
        )
        let frame = try TransferChunkCrypto.seal(
            plaintext: Data("hello".utf8),
            header: header,
            using: key
        )
        let tampered = EncryptedChunkFrame(
            header: TransferChunkHeader(
                transferID: header.transferID,
                fileID: header.fileID,
                sequence: 0,
                offset: 64,
                plaintextCount: 5,
                isFinal: true
            ),
            nonce: frame.nonce,
            ciphertext: frame.ciphertext,
            authenticationTag: frame.authenticationTag
        )
        #expect(throws: TransferProtocolError.authenticationFailed) {
            try TransferChunkCrypto.open(tampered, using: key)
        }
    }

    private func makeSession(
        role: TransferRole,
        sessionID: UUID,
        transferID: UUID,
        privateValue: UInt8,
        nonce: UInt8
    ) throws -> NearbyTransferSession {
        var key = Data(repeating: 0, count: 32)
        key[key.count - 1] = privateValue
        return try NearbyTransferSession(
            role: role,
            sessionID: sessionID,
            transferID: transferID,
            rawPrivateKey: key,
            localNonce: Data(repeating: nonce, count: 32)
        )
    }

    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
