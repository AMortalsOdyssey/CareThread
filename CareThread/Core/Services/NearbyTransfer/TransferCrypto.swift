import CryptoKit
import Foundation

struct TransferSessionHello: Codable, Hashable, Sendable {
    let protocolVersion: Int
    let role: TransferRole
    let sessionID: UUID
    let transferID: UUID
    let keyEpoch: UInt64
    let publicKey: Data
    let randomNonce: Data
}

struct TransferKeyConfirmation: Codable, Equatable, Sendable {
    let role: TransferRole
    let sessionID: UUID
    let transferID: UUID
    let keyEpoch: UInt64
    let transcriptSHA256: Data
    let authenticationTag: Data
}

private struct TransferSessionKeySet: Sendable {
    let senderToReceiverChunk: SymmetricKey
    let receiverToSenderChunk: SymmetricKey
    let senderToReceiverManifest: SymmetricKey
    let receiverToSenderManifest: SymmetricKey
    let senderConfirmation: SymmetricKey
    let receiverConfirmation: SymmetricKey
    let senderCommitReceipt: SymmetricKey
    let receiverCommitReceipt: SymmetricKey
    let sas: SymmetricKey
}

enum TransferTrafficDirection: String, Codable, Sendable {
    case senderToReceiver
    case receiverToSender
}

struct TransferManifestAAD: Codable, Equatable, Sendable {
    let context: String
    let protocolVersion: Int
    let sessionID: UUID
    let transferID: UUID
    let keyEpoch: UInt64
    let direction: TransferTrafficDirection
    let message: String

    init(
        sessionID: UUID,
        transferID: UUID,
        keyEpoch: UInt64,
        direction: TransferTrafficDirection
    ) {
        context = "CareThread/NearbyTransfer/AEAD/v1"
        protocolVersion = 1
        self.sessionID = sessionID
        self.transferID = transferID
        self.keyEpoch = keyEpoch
        self.direction = direction
        message = "manifest"
    }
}

enum SecureTransferRandom {
    static func bytes(count: Int) throws -> Data {
        guard count > 0, count <= 1_024 else {
            throw TransferProtocolError.entropyUnavailable
        }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TransferProtocolError.entropyUnavailable
        }
        return Data(bytes)
    }
}

/// Owns the complete authenticated pairing lifecycle. Callers can request content
/// keys only after both users confirmed the same SAS and both key-confirmation
/// MACs were validated.
actor NearbyTransferSession {
    private let role: TransferRole
    private let sessionID: UUID
    private let transferID: UUID
    private var keyEpoch: UInt64
    private var agreement: P256.KeyAgreement.PrivateKey
    private var localNonce: Data
    private var peerHello: TransferSessionHello?
    private var transcript: Data?
    private var keys: TransferSessionKeySet?
    private var localSASConfirmed = false
    private var peerKeyConfirmed = false

    init(
        role: TransferRole,
        sessionID: UUID = UUID(),
        transferID: UUID,
        keyEpoch: UInt64 = 0,
        entropy: @Sendable (Int) throws -> Data = {
            try SecureTransferRandom.bytes(count: $0)
        }
    ) throws {
        self.role = role
        self.sessionID = sessionID
        self.transferID = transferID
        self.keyEpoch = keyEpoch
        agreement = P256.KeyAgreement.PrivateKey()
        let nonce = try entropy(32)
        guard nonce.count == 32 else {
            throw TransferProtocolError.entropyUnavailable
        }
        localNonce = nonce
    }

    init(
        role: TransferRole,
        sessionID: UUID,
        transferID: UUID,
        keyEpoch: UInt64 = 0,
        rawPrivateKey: Data,
        localNonce: Data
    ) throws {
        guard localNonce.count == 32 else {
            throw TransferProtocolError.invalidManifest("session nonce")
        }
        self.role = role
        self.sessionID = sessionID
        self.transferID = transferID
        self.keyEpoch = keyEpoch
        do {
            agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
        } catch {
            throw TransferProtocolError.invalidPublicKey
        }
        self.localNonce = localNonce
    }

    func localHello() -> TransferSessionHello {
        TransferSessionHello(
            protocolVersion: TransferLimits.protocolVersion,
            role: role,
            sessionID: sessionID,
            transferID: transferID,
            keyEpoch: keyEpoch,
            publicKey: agreement.publicKey.x963Representation,
            randomNonce: localNonce
        )
    }

    func receivePeerHello(_ hello: TransferSessionHello) throws {
        guard hello.protocolVersion == TransferLimits.protocolVersion,
              hello.role != role,
              hello.sessionID == sessionID,
              hello.transferID == transferID,
              hello.keyEpoch == keyEpoch,
              hello.randomNonce.count == 32,
              hello.randomNonce != localNonce,
              peerHello == nil else {
            throw TransferProtocolError.invalidManifest("session hello mismatch")
        }
        let peerPublicKey: P256.KeyAgreement.PublicKey
        do {
            peerPublicKey = try P256.KeyAgreement.PublicKey(
                x963Representation: hello.publicKey
            )
        } catch {
            throw TransferProtocolError.invalidPublicKey
        }
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try agreement.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } catch {
            throw TransferProtocolError.invalidPublicKey
        }

        let local = localHello()
        let senderHello = role == .sender ? local : hello
        let receiverHello = role == .receiver ? local : hello
        let transcriptValue = TransferHandshakeTranscript(
            context: "CareThread/NearbyTransfer/Handshake/v1",
            protocolVersion: TransferLimits.protocolVersion,
            sessionID: sessionID,
            transferID: transferID,
            keyEpoch: keyEpoch,
            senderPublicKey: senderHello.publicKey,
            receiverPublicKey: receiverHello.publicKey,
            senderNonce: senderHello.randomNonce,
            receiverNonce: receiverHello.randomNonce
        )
        let transcript = try StableJSON.encode(transcriptValue)
        let root = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: transcript)),
            sharedInfo: Data("CareThread/NearbyTransfer/Root/v1".utf8),
            outputByteCount: 32
        )
        keys = TransferSessionKeySet(
            senderToReceiverChunk: Self.derive(root, "chunk/sender-to-receiver"),
            receiverToSenderChunk: Self.derive(root, "chunk/receiver-to-sender"),
            senderToReceiverManifest: Self.derive(root, "manifest/sender-to-receiver"),
            receiverToSenderManifest: Self.derive(root, "manifest/receiver-to-sender"),
            senderConfirmation: Self.derive(root, "confirm/sender"),
            receiverConfirmation: Self.derive(root, "confirm/receiver"),
            senderCommitReceipt: Self.derive(root, "commit/sender"),
            receiverCommitReceipt: Self.derive(root, "commit/receiver"),
            sas: Self.derive(root, "sas")
        )
        self.transcript = transcript
        peerHello = hello
    }

    func pairingCode() throws -> String {
        guard let keys, let transcript else {
            throw TransferProtocolError.invalidStateTransition
        }
        let mac = HMAC<SHA256>.authenticationCode(for: transcript, using: keys.sas)
        let prefix = Array(mac.prefix(4))
        let value = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    func confirmPairing(codeMatches: Bool) throws -> TransferKeyConfirmation {
        guard codeMatches else {
            throw TransferProtocolError.authenticationFailed
        }
        guard let keys, let transcript else {
            throw TransferProtocolError.invalidStateTransition
        }
        localSASConfirmed = true
        let digest = Data(SHA256.hash(data: transcript))
        let unsigned = TransferKeyConfirmationUnsigned(
            role: role,
            sessionID: sessionID,
            transferID: transferID,
            keyEpoch: keyEpoch,
            transcriptSHA256: digest
        )
        let key = role == .sender ? keys.senderConfirmation : keys.receiverConfirmation
        let tag = HMAC<SHA256>.authenticationCode(
            for: try StableJSON.encode(unsigned),
            using: key
        )
        return TransferKeyConfirmation(
            role: role,
            sessionID: sessionID,
            transferID: transferID,
            keyEpoch: keyEpoch,
            transcriptSHA256: digest,
            authenticationTag: Data(tag)
        )
    }

    func receivePeerKeyConfirmation(_ confirmation: TransferKeyConfirmation) throws {
        guard let keys, let transcript,
              confirmation.role != role,
              confirmation.sessionID == sessionID,
              confirmation.transferID == transferID,
              confirmation.keyEpoch == keyEpoch,
              confirmation.transcriptSHA256 == Data(SHA256.hash(data: transcript)) else {
            throw TransferProtocolError.keyConfirmationFailed
        }
        let unsigned = TransferKeyConfirmationUnsigned(
            role: confirmation.role,
            sessionID: confirmation.sessionID,
            transferID: confirmation.transferID,
            keyEpoch: confirmation.keyEpoch,
            transcriptSHA256: confirmation.transcriptSHA256
        )
        let key = confirmation.role == .sender
            ? keys.senderConfirmation
            : keys.receiverConfirmation
        guard HMAC<SHA256>.isValidAuthenticationCode(
            confirmation.authenticationTag,
            authenticating: try StableJSON.encode(unsigned),
            using: key
        ) else {
            throw TransferProtocolError.keyConfirmationFailed
        }
        peerKeyConfirmed = true
    }

    func isAuthorizedForSensitiveFrames() -> Bool {
        localSASConfirmed && peerKeyConfirmed
    }

    func sealOutgoingManifest(_ manifest: TransferManifest) throws -> SealedTransferManifest {
        try requireAuthorized()
        return try SealedTransferManifest.seal(
            manifest,
            using: try outgoingKey(for: .manifest),
            aad: manifestAAD(direction: outgoingDirection)
        )
    }

    func openIncomingManifest(
        _ sealed: SealedTransferManifest,
        existingPatientIDs: Set<UUID> = []
    ) throws -> TransferManifest {
        try requireAuthorized()
        return try sealed.verifiedManifest(
            using: try incomingKey(for: .manifest),
            expectedAAD: manifestAAD(direction: incomingDirection),
            existingPatientIDs: existingPatientIDs
        )
    }

    func outgoingChunkKey() throws -> SymmetricKey {
        try requireAuthorized()
        return try outgoingKey(for: .chunk)
    }

    func incomingChunkKey() throws -> SymmetricKey {
        try requireAuthorized()
        return try incomingKey(for: .chunk)
    }

    func receiverCommitReceiptKey() throws -> SymmetricKey {
        try requireAuthorized()
        guard role == .receiver, let keys else {
            throw TransferProtocolError.invalidStateTransition
        }
        return keys.receiverCommitReceipt
    }

    func senderExpectedCommitReceiptKey() throws -> SymmetricKey {
        try requireAuthorized()
        guard role == .sender, let keys else {
            throw TransferProtocolError.invalidStateTransition
        }
        return keys.receiverCommitReceipt
    }

    /// Reconnection always discards prior traffic keys and SAS confirmation.
    func beginNewKeyEpoch() throws -> TransferSessionHello {
        guard keyEpoch < UInt64.max else {
            throw TransferProtocolError.limitExceeded("key epoch")
        }
        keyEpoch += 1
        agreement = P256.KeyAgreement.PrivateKey()
        localNonce = try SecureTransferRandom.bytes(count: 32)
        peerHello = nil
        transcript = nil
        keys = nil
        localSASConfirmed = false
        peerKeyConfirmed = false
        return localHello()
    }

    private enum ContentPurpose {
        case chunk
        case manifest
    }

    private func outgoingKey(for purpose: ContentPurpose) throws -> SymmetricKey {
        guard let keys else { throw TransferProtocolError.invalidStateTransition }
        switch (role, purpose) {
        case (.sender, .chunk): return keys.senderToReceiverChunk
        case (.receiver, .chunk): return keys.receiverToSenderChunk
        case (.sender, .manifest): return keys.senderToReceiverManifest
        case (.receiver, .manifest): return keys.receiverToSenderManifest
        }
    }

    private func incomingKey(for purpose: ContentPurpose) throws -> SymmetricKey {
        guard let keys else { throw TransferProtocolError.invalidStateTransition }
        switch (role, purpose) {
        case (.sender, .chunk): return keys.receiverToSenderChunk
        case (.receiver, .chunk): return keys.senderToReceiverChunk
        case (.sender, .manifest): return keys.receiverToSenderManifest
        case (.receiver, .manifest): return keys.senderToReceiverManifest
        }
    }

    private func requireAuthorized() throws {
        guard localSASConfirmed, peerKeyConfirmed else {
            throw TransferProtocolError.pairingNotConfirmed
        }
    }

    private var outgoingDirection: TransferTrafficDirection {
        role == .sender ? .senderToReceiver : .receiverToSender
    }

    private var incomingDirection: TransferTrafficDirection {
        role == .sender ? .receiverToSender : .senderToReceiver
    }

    private func manifestAAD(direction: TransferTrafficDirection) -> TransferManifestAAD {
        TransferManifestAAD(
            sessionID: sessionID,
            transferID: transferID,
            keyEpoch: keyEpoch,
            direction: direction
        )
    }

    private static func derive(_ root: SymmetricKey, _ label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: root,
            salt: Data(),
            info: Data("CareThread/NearbyTransfer/\(label)/v1".utf8),
            outputByteCount: 32
        )
    }

}

private struct TransferHandshakeTranscript: Codable {
    let context: String
    let protocolVersion: Int
    let sessionID: UUID
    let transferID: UUID
    let keyEpoch: UInt64
    let senderPublicKey: Data
    let receiverPublicKey: Data
    let senderNonce: Data
    let receiverNonce: Data
}

private struct TransferKeyConfirmationUnsigned: Codable {
    let role: TransferRole
    let sessionID: UUID
    let transferID: UUID
    let keyEpoch: UInt64
    let transcriptSHA256: Data
}

struct SealedTransferManifest: Codable, Equatable, Sendable {
    let aad: TransferManifestAAD
    let nonce: Data
    /// Ciphertext only. Plain manifest JSON never crosses the transport.
    let manifestBytes: Data
    let manifestSHA256: String
    let authenticationTag: Data

    fileprivate static func seal(
        _ manifest: TransferManifest,
        using key: SymmetricKey,
        aad: TransferManifestAAD
    ) throws -> Self {
        try manifest.validate()
        guard aad.protocolVersion == 1,
              aad.transferID == manifest.transferID,
              aad.message == "manifest" else {
            throw TransferProtocolError.manifestIntegrityFailed
        }
        let encoded = try StableJSON.encode(manifest)
        guard encoded.count <= TransferLimits.maximumManifestBytes else {
            throw TransferProtocolError.limitExceeded("manifest bytes")
        }
        let digest = SHA256.hash(data: encoded)
        let aadBytes = try StableJSON.encode(aad)
        let sealed = try ChaChaPoly.seal(encoded, using: key, authenticating: aadBytes)
        return Self(
            aad: aad,
            nonce: Data(sealed.nonce),
            manifestBytes: sealed.ciphertext,
            manifestSHA256: Data(digest).hexString,
            authenticationTag: sealed.tag
        )
    }

    fileprivate func verifiedManifest(
        using key: SymmetricKey,
        expectedAAD: TransferManifestAAD,
        receiverProtocolVersion: Int = TransferLimits.protocolVersion,
        existingPatientIDs: Set<UUID> = []
    ) throws -> TransferManifest {
        guard manifestBytes.count <= TransferLimits.maximumManifestBytes,
              nonce.count == 12,
              authenticationTag.count == 16,
              manifestSHA256.count == 64 else {
            throw TransferProtocolError.limitExceeded("manifest bytes")
        }
        guard aad == expectedAAD,
              aad.protocolVersion == 1,
              aad.message == "manifest" else {
            throw TransferProtocolError.authenticationFailed
        }
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce),
                ciphertext: manifestBytes,
                tag: authenticationTag
            )
            plaintext = try ChaChaPoly.open(
                box,
                using: key,
                authenticating: StableJSON.encode(aad)
            )
        } catch {
            throw TransferProtocolError.authenticationFailed
        }
        let digest = Data(SHA256.hash(data: plaintext)).hexString
        guard digest == manifestSHA256.lowercased() else {
            throw TransferProtocolError.manifestIntegrityFailed
        }
        return try TransferManifest.decodeAndValidate(
            from: plaintext,
            receiverProtocolVersion: receiverProtocolVersion,
            existingPatientIDs: existingPatientIDs
        )
    }
}

enum TransferFileHashing {
    static func sha256(url: URL, bufferSize: Int = TransferLimits.chunkSize) throws -> String {
        guard bufferSize > 0, bufferSize <= TransferLimits.chunkSize else {
            throw TransferProtocolError.invalidChunk("invalid hashing buffer")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: bufferSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize()).hexString
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
