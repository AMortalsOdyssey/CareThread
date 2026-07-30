import CryptoKit
import Foundation
@testable import CareThread

struct AuthorizedTransferSessions {
    let sender: NearbyTransferSession
    let receiver: NearbyTransferSession

    static func make(
        transferID: UUID,
        sessionID: UUID = UUID(
            uuidString: "90000000-0000-0000-0000-000000000009"
        )!
    ) async throws -> Self {
        let sender = try NearbyTransferSession(
            role: .sender,
            sessionID: sessionID,
            transferID: transferID,
            rawPrivateKey: fixedPrivateKey(1),
            localNonce: Data(repeating: 0x11, count: 32)
        )
        let receiver = try NearbyTransferSession(
            role: .receiver,
            sessionID: sessionID,
            transferID: transferID,
            rawPrivateKey: fixedPrivateKey(2),
            localNonce: Data(repeating: 0x22, count: 32)
        )
        let senderHello = await sender.localHello()
        let receiverHello = await receiver.localHello()
        try await sender.receivePeerHello(receiverHello)
        try await receiver.receivePeerHello(senderHello)
        let senderCode = try await sender.pairingCode()
        let receiverCode = try await receiver.pairingCode()
        guard senderCode == receiverCode else {
            throw TransferProtocolError.authenticationFailed
        }
        let senderConfirmation = try await sender.confirmPairing(codeMatches: true)
        let receiverConfirmation = try await receiver.confirmPairing(codeMatches: true)
        try await sender.receivePeerKeyConfirmation(receiverConfirmation)
        try await receiver.receivePeerKeyConfirmation(senderConfirmation)
        return Self(sender: sender, receiver: receiver)
    }

    private static func fixedPrivateKey(_ value: UInt8) -> Data {
        var data = Data(repeating: 0, count: 32)
        data[data.count - 1] = value
        return data
    }
}

struct TransferTestFixture {
    let manifest: TransferManifest
    let patientIDs: [UUID]
    let payloads: [UUID: Data]

    static func single(
        protocolVersion: Int = 1,
        minimumReceiverVersion: Int = 1
    ) -> Self {
        let patientID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        return make(
            patientIDs: [patientID],
            scope: .singlePatient(patientID),
            protocolVersion: protocolVersion,
            minimumReceiverVersion: minimumReceiverVersion
        )
    }

    static func all() -> Self {
        let patientIDs = [
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        ]
        return make(
            patientIDs: patientIDs,
            scope: .allPatients,
            protocolVersion: 1,
            minimumReceiverVersion: 1
        )
    }

    enum AttachmentGraphAttack: Equatable {
        case none
        case missingRecordReference
        case swappedOriginalFile
        case orphanDomainPayload
    }

    static func attachmentGraph(
        attack: AttachmentGraphAttack = .none
    ) -> Self {
        let patientID = UUID(
            uuidString: "A1000000-0000-0000-0000-000000000001"
        )!
        let recordID = UUID(
            uuidString: "A2000000-0000-0000-0000-000000000002"
        )!
        let attachmentID = UUID(
            uuidString: "A3000000-0000-0000-0000-000000000003"
        )!
        let originalFileID = UUID(
            uuidString: "A4000000-0000-0000-0000-000000000004"
        )!
        let original = Data("fictional-original-medical-image".utf8)
        let originalHash = Data(SHA256.hash(data: original)).testHex

        let domain: [(TransferEntityKind, UUID, TransferDomainEnvelopeV1)] = [
            (
                .patient,
                patientID,
                TransferDomainEnvelopeV1(
                    kind: .patient,
                    entityID: patientID,
                    patientID: patientID,
                    revision: 1,
                    fields: ["displayName": "虚构成员"]
                )
            ),
            (
                .medicalRecord,
                recordID,
                TransferDomainEnvelopeV1(
                    kind: .medicalRecord,
                    entityID: recordID,
                    patientID: patientID,
                    revision: 1,
                    fields: [
                        "recordType": "lab",
                        "eventDateUTC": "2026-07-31T00:00:00Z",
                        "title": "虚构检查"
                    ]
                )
            ),
            (
                .attachment,
                attachmentID,
                TransferDomainEnvelopeV1(
                    kind: .attachment,
                    entityID: attachmentID,
                    patientID: patientID,
                    revision: 1,
                    references: attack == .missingRecordReference
                        ? []
                        : [
                            TransferEntityReference(
                                entityID: recordID,
                                kind: .medicalRecord
                            )
                        ],
                    fields: [
                        "recordID": recordID.uuidString,
                        "originalFileID": (
                            attack == .swappedOriginalFile ? UUID() : originalFileID
                        ).uuidString,
                        "mediaType": "image/jpeg",
                        "sha256": originalHash
                    ]
                )
            )
        ]
        var payloads: [UUID: Data] = [originalFileID: original]
        var files: [TransferFileDescriptor] = []
        var entities: [TransferEntityDescriptor] = []
        for (index, item) in domain.enumerated() {
            let fileID = UUID(
                uuidString: String(
                    format: "A5000000-0000-0000-0000-%012d",
                    index + 1
                )
            )!
            let payload = try! StableJSON.encode(item.2)
            payloads[fileID] = payload
            files.append(
                TransferFileDescriptor(
                    kind: .domainSnapshot,
                    fileID: fileID,
                    patientID: patientID,
                    relativePath:
                        "members/\(patientID.uuidString.lowercased())/domain-\(index).json",
                    byteCount: Int64(payload.count),
                    sha256: Data(SHA256.hash(data: payload)).testHex
                )
            )
            entities.append(
                TransferEntityDescriptor(
                    kind: item.0,
                    entityID: item.1,
                    patientID: patientID,
                    payloadFileID: fileID,
                    revision: 1
                )
            )
        }
        files.append(
            TransferFileDescriptor(
                kind: .originalAttachment,
                fileID: originalFileID,
                patientID: patientID,
                ownerAttachmentID: attachmentID,
                relativePath:
                    "members/\(patientID.uuidString.lowercased())/original.jpg",
                byteCount: Int64(original.count),
                sha256: originalHash
            )
        )
        if attack == .orphanDomainPayload {
            let orphanID = UUID(
                uuidString: "A6000000-0000-0000-0000-000000000006"
            )!
            let payload = try! StableJSON.encode(
                TransferDomainEnvelopeV1(
                    kind: .patient,
                    entityID: orphanID,
                    patientID: patientID,
                    revision: 1,
                    fields: ["displayName": "孤儿 payload"]
                )
            )
            payloads[orphanID] = payload
            files.append(
                TransferFileDescriptor(
                    kind: .domainSnapshot,
                    fileID: orphanID,
                    patientID: patientID,
                    relativePath:
                        "members/\(patientID.uuidString.lowercased())/orphan.json",
                    byteCount: Int64(payload.count),
                    sha256: Data(SHA256.hash(data: payload)).testHex
                )
            )
        }
        let manifest = TransferManifest(
            transferID: UUID(
                uuidString: "AE000000-0000-0000-0000-000000000001"
            )!,
            scope: .singlePatient(patientID),
            createdAtUTC: "2026-07-31T00:00:00Z",
            capabilities: [
                TransferCapability(identifier: "domain.json", version: 1),
                TransferCapability(identifier: "vault.original", version: 1)
            ],
            preview: .init(memberCount: 1, recordCount: 1, attachmentCount: 1),
            entities: entities,
            files: files
        )
        return Self(manifest: manifest, patientIDs: [patientID], payloads: payloads)
    }

    private static func make(
        patientIDs: [UUID],
        scope: TransferScope,
        protocolVersion: Int,
        minimumReceiverVersion: Int
    ) -> Self {
        var payloads: [UUID: Data] = [:]
        var files: [TransferFileDescriptor] = []
        var entities: [TransferEntityDescriptor] = []
        for (index, patientID) in patientIDs.enumerated() {
            let fileID = UUID(uuidString: String(
                format: "CCCCCCCC-0000-0000-0000-%012d",
                index + 1
            ))!
            let envelope = TransferDomainEnvelopeV1(
                kind: .patient,
                entityID: patientID,
                patientID: patientID,
                revision: 1,
                fields: ["displayName": "虚构成员\(index + 1)"]
            )
            let payload = try! StableJSON.encode(envelope)
            payloads[fileID] = payload
            files.append(
                TransferFileDescriptor(
                    kind: .domainSnapshot,
                    fileID: fileID,
                    patientID: patientID,
                    relativePath:
                        "members/\(patientID.uuidString.lowercased())/domain-\(index).json",
                    byteCount: Int64(payload.count),
                    sha256: Data(SHA256.hash(data: payload)).testHex
                )
            )
            entities.append(
                TransferEntityDescriptor(
                    kind: .patient,
                    entityID: patientID,
                    patientID: patientID,
                    payloadFileID: fileID,
                    revision: 1
                )
            )
        }
        let manifest = TransferManifest(
            protocolVersion: protocolVersion,
            minimumReceiverVersion: minimumReceiverVersion,
            transferID: UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!,
            scope: scope,
            createdAtUTC: "2026-07-31T00:00:00Z",
            capabilities: [
                TransferCapability(identifier: "domain.json", version: 1),
                TransferCapability(identifier: "vault.original", version: 1)
            ],
            preview: TransferPreviewCounts(
                memberCount: patientIDs.count,
                recordCount: 0,
                attachmentCount: 0
            ),
            entities: entities,
            files: files
        )
        return Self(manifest: manifest, patientIDs: patientIDs, payloads: payloads)
    }
}

func stageTransferFixture(
    _ fixture: TransferTestFixture,
    sessions: AuthorizedTransferSessions,
    rootURL: URL
) async throws -> TransferStagingStore {
    let sourceDirectory = rootURL.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sourceDirectory,
        withIntermediateDirectories: true
    )
    let store = try TransferStagingStore(
        rootURL: rootURL.appendingPathComponent("staging", isDirectory: true)
    )
    let outgoingKey = try await sessions.sender.outgoingChunkKey()
    let incomingKey = try await sessions.receiver.incomingChunkKey()
    for descriptor in fixture.manifest.files {
        let validated = try descriptor.validated()
        let payload = fixture.payloads[descriptor.fileID]!
        let sourceURL = sourceDirectory.appendingPathComponent(descriptor.fileID.uuidString)
        try payload.write(to: sourceURL)
        let reader = try TransferFileChunkReader(
            fileURL: sourceURL,
            descriptor: validated,
            transferID: fixture.manifest.transferID,
            key: outgoingKey
        )
        let receiver = try await TransferFileChunkReceiver.make(
            stagingStore: store,
            descriptor: validated,
            transferID: fixture.manifest.transferID,
            key: incomingKey
        )
        while let frame = try await reader.nextFrame() {
            _ = try await receiver.accept(frame)
        }
        try await receiver.finalize()
    }
    return store
}

extension Data {
    var testHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private func fixedPrivateKey(_ value: UInt8) -> Data {
    var data = Data(repeating: 0, count: 32)
    data[data.count - 1] = value
    return data
}
