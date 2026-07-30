import CryptoKit
import Foundation
import Testing
@testable import CareThread

struct NearbyTransferSecurityContractTests {
    @Test("manifest wire bytes are AEAD ciphertext, not decodable JSON")
    func manifestIsConfidential() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        #expect(throws: (any Error).self) {
            _ = try JSONSerialization.jsonObject(with: sealed.manifestBytes)
        }
        #expect(sealed.authenticationTag.count == 16)
        #expect(sealed.nonce.count == 12)
    }

    @Test("manifest AAD direction tamper fails authentication")
    func manifestDirectionIsBound() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        let attacked = SealedTransferManifest(
            aad: TransferManifestAAD(
                sessionID: sealed.aad.sessionID,
                transferID: sealed.aad.transferID,
                keyEpoch: sealed.aad.keyEpoch,
                direction: .receiverToSender
            ),
            nonce: sealed.nonce,
            manifestBytes: sealed.manifestBytes,
            manifestSHA256: sealed.manifestSHA256,
            authenticationTag: sealed.authenticationTag
        )
        await #expect(throws: TransferProtocolError.authenticationFailed) {
            _ = try await sessions.receiver.openIncomingManifest(attacked)
        }
    }

    @Test("manifest AAD epoch tamper fails authentication")
    func manifestEpochIsBound() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        let attacked = SealedTransferManifest(
            aad: TransferManifestAAD(
                sessionID: sealed.aad.sessionID,
                transferID: sealed.aad.transferID,
                keyEpoch: sealed.aad.keyEpoch + 1,
                direction: sealed.aad.direction
            ),
            nonce: sealed.nonce,
            manifestBytes: sealed.manifestBytes,
            manifestSHA256: sealed.manifestSHA256,
            authenticationTag: sealed.authenticationTag
        )
        await #expect(throws: TransferProtocolError.authenticationFailed) {
            _ = try await sessions.receiver.openIncomingManifest(attacked)
        }
    }

    @Test("manifest ciphertext tamper fails before JSON decoding")
    func manifestCiphertextTamperFails() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        var ciphertext = sealed.manifestBytes
        ciphertext[ciphertext.startIndex] ^= 0x80
        let attacked = SealedTransferManifest(
            aad: sealed.aad,
            nonce: sealed.nonce,
            manifestBytes: ciphertext,
            manifestSHA256: sealed.manifestSHA256,
            authenticationTag: sealed.authenticationTag
        )
        await #expect(throws: TransferProtocolError.authenticationFailed) {
            _ = try await sessions.receiver.openIncomingManifest(attacked)
        }
    }

    @Test("secure entropy failure is fail-closed")
    func entropyFailureIsFailClosed() {
        #expect(throws: TransferProtocolError.entropyUnavailable) {
            _ = try NearbyTransferSession(
                role: .sender,
                transferID: UUID()
            ) { _ in
                throw TransferProtocolError.entropyUnavailable
            }
        }
    }

    @Test("protocol minimum must be exactly v1")
    func minimumVersionMustBeExactlyV1() {
        let base = TransferTestFixture.single()
        let manifest = TransferManifest(
            protocolVersion: 1,
            minimumReceiverVersion: 0,
            transferID: base.manifest.transferID,
            scope: base.manifest.scope,
            createdAtUTC: base.manifest.createdAtUTC,
            capabilities: base.manifest.capabilities,
            preview: base.manifest.preview,
            entities: base.manifest.entities,
            files: base.manifest.files
        )
        #expect(throws: TransferProtocolError.self) {
            try manifest.validate()
        }
    }

    @Test("nested manifest capability rejects unknown keys")
    func nestedManifestKeysAreStrict() throws {
        let data = try StableJSON.encode(TransferTestFixture.single().manifest)
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var capabilities = try #require(root["capabilities"] as? [[String: Any]])
        capabilities[0]["ignored"] = true
        root["capabilities"] = capabilities
        let attacked = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: TransferProtocolError.self) {
            _ = try TransferManifest.decodeAndValidate(from: attacked)
        }
    }

    @Test("nested domain references reject unknown keys")
    func nestedDomainReferenceKeysAreStrict() throws {
        let patientID = UUID()
        let recordID = UUID()
        let envelope = TransferDomainEnvelopeV1(
            kind: .recordTag,
            entityID: UUID(),
            patientID: patientID,
            revision: 1,
            references: [
                TransferEntityReference(entityID: recordID, kind: .medicalRecord)
            ],
            fields: ["recordID": recordID.uuidString, "name": "重要"]
        )
        var root = try #require(
            JSONSerialization.jsonObject(with: StableJSON.encode(envelope))
                as? [String: Any]
        )
        var references = try #require(root["references"] as? [[String: Any]])
        references[0]["ignored"] = "attack"
        root["references"] = references
        let attacked = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: TransferProtocolError.self) {
            _ = try TransferDomainEnvelopeV1.decodeStrict(from: attacked)
        }
    }

    @Test("typed patient payload rejects unversioned field")
    func typedFieldsRejectUnknownField() throws {
        let patientID = UUID()
        let envelope = TransferDomainEnvelopeV1(
            kind: .patient,
            entityID: patientID,
            patientID: patientID,
            revision: 1,
            fields: ["displayName": "虚构成员", "surprise": "ignored"]
        )
        #expect(throws: TransferProtocolError.self) {
            _ = try TransferDomainEnvelopeV1.decodeStrict(
                from: StableJSON.encode(envelope)
            )
        }
    }

    @Test("recordTag and contentRevision are legal typed V1 kinds")
    func addedKindsDecodeStrictly() throws {
        let patientID = UUID()
        let recordID = UUID()
        let tag = TransferDomainEnvelopeV1(
            kind: .recordTag,
            entityID: UUID(),
            patientID: patientID,
            revision: 1,
            references: [
                TransferEntityReference(entityID: recordID, kind: .medicalRecord)
            ],
            fields: ["recordID": recordID.uuidString, "name": "复查"]
        )
        #expect(
            try TransferDomainEnvelopeV1.decodeStrict(
                from: StableJSON.encode(tag)
            ).kind == .recordTag
        )
        let revision = TransferDomainEnvelopeV1(
            kind: .contentRevision,
            entityID: UUID(),
            patientID: patientID,
            revision: 1,
            references: [
                TransferEntityReference(entityID: recordID, kind: .medicalRecord)
            ],
            fields: [
                "targetEntityID": recordID.uuidString,
                "targetKind": TransferEntityKind.medicalRecord.rawValue,
                "revision": "1",
                "payloadSHA256": String(repeating: "a", count: 64)
            ]
        )
        #expect(
            try TransferDomainEnvelopeV1.decodeStrict(
                from: StableJSON.encode(revision)
            ).kind == .contentRevision
        )
    }

    @Test("original descriptor requires reverse owner")
    func originalRequiresOwner() {
        let patientID = UUID()
        let descriptor = TransferFileDescriptor(
            kind: .originalAttachment,
            fileID: UUID(),
            patientID: patientID,
            relativePath: "members/\(patientID.uuidString.lowercased())/original.bin",
            byteCount: 1,
            sha256: String(repeating: "a", count: 64)
        )
        #expect(throws: TransferProtocolError.self) {
            _ = try descriptor.validated()
        }
    }

    @Test("manifest rejects two originals claiming one attachment")
    func duplicateOriginalOwnerIsRejected() {
        let manifest = attachmentManifest(originalCount: 2)
        #expect(throws: TransferProtocolError.self) {
            try manifest.validate()
        }
    }

    @Test("manifest rejects attachment without original")
    func missingOriginalOwnerIsRejected() {
        let manifest = attachmentManifest(originalCount: 0)
        #expect(throws: TransferProtocolError.self) {
            try manifest.validate()
        }
    }

    @Test("UUID same fingerprint is idempotent")
    func uuidSameFingerprintIsIdempotent() throws {
        let id = UUID()
        let hash = String(repeating: "a", count: 64)
        let result = try TransferUUIDConflictPolicyV1.preflight(
            incoming: [id: hash],
            existing: [id: hash]
        )
        #expect(result[id] == .idempotentExisting)
    }

    @Test("UUID different fingerprint aborts")
    func uuidDifferentFingerprintAborts() {
        let id = UUID()
        #expect(throws: TransferProtocolError.uuidConflict(id)) {
            _ = try TransferUUIDConflictPolicyV1.preflight(
                incoming: [id: String(repeating: "a", count: 64)],
                existing: [id: String(repeating: "b", count: 64)]
            )
        }
    }

    @Test("incremental parser accepts every-byte fragmentation")
    func parserAcceptsFragmentation() throws {
        let encoded = try NearbyWireFrameCodec.encode(
            NearbyWireFrame(category: .handshake, payload: Data("hello".utf8))
        )
        var parser = IncrementalNearbyWireParser()
        var frames: [NearbyWireFrame] = []
        for byte in encoded {
            frames += try parser.append(Data([byte]))
        }
        #expect(frames == [
            NearbyWireFrame(category: .handshake, payload: Data("hello".utf8))
        ])
        #expect(parser.bufferedByteCount == 0)
    }

    @Test("incremental parser accepts legal coalesced frames")
    func parserAcceptsCoalescing() throws {
        let one = try NearbyWireFrameCodec.encode(
            NearbyWireFrame(category: .control, payload: Data("one".utf8))
        )
        let two = try NearbyWireFrameCodec.encode(
            NearbyWireFrame(category: .commitReceipt, payload: Data("two".utf8))
        )
        var parser = IncrementalNearbyWireParser()
        let frames = try parser.append(one + two)
        #expect(frames.map(\.category) == [.control, .commitReceipt])
        #expect(parser.frameCount == 2)
    }

    @Test("parser rejects category length before payload allocation")
    func parserRejectsDeclaredCategoryOverflow() {
        var header = Data([0x43, 0x54, 0x01, NearbyWireFrameCategory.commitReceipt.rawValue])
        var size = UInt32(TransferLimits.maximumReceiptFrameBytes + 1).bigEndian
        Swift.withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        var parser = IncrementalNearbyWireParser()
        #expect(throws: TransferProtocolError.self) {
            _ = try parser.append(header)
        }
    }

    @Test("parser rejects non-v1 frame version")
    func parserRejectsWrongVersion() {
        var header = Data([0x43, 0x54, 0x02, NearbyWireFrameCategory.control.rawValue])
        var size = UInt32(1).bigEndian
        Swift.withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        header.append(0)
        var parser = IncrementalNearbyWireParser()
        #expect(throws: TransferProtocolError.self) {
            _ = try parser.append(header)
        }
    }

    @Test("parser rejects oversized receive segment")
    func parserRejectsOversizedSegment() {
        var parser = IncrementalNearbyWireParser()
        #expect(throws: TransferProtocolError.self) {
            _ = try parser.append(
                Data(
                    repeating: 0,
                    count: NearbyNetworkConfiguration.maximumReceiveSegmentBytes + 1
                )
            )
        }
    }

    @Test("deadline cancels cooperative operation and reports class")
    func deadlineTimesOut() async {
        await #expect(throws: TransferProtocolError.timedOut("handshake")) {
            _ = try await TransferDeadline.run(
                operation: .handshake,
                nanoseconds: 1_000_000
            ) {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return true
            }
        }
    }

    @Test("staging quota rejects reservation before file transfer")
    func stagingQuotaIsEnforced() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let patientID = UUID()
        let attachmentID = UUID()
        let descriptor = try TransferFileDescriptor(
            kind: .originalAttachment,
            fileID: UUID(),
            patientID: patientID,
            ownerAttachmentID: attachmentID,
            relativePath: "members/\(patientID.uuidString.lowercased())/large.bin",
            byteCount: 2,
            sha256: String(repeating: "a", count: 64)
        ).validated()
        let store = try TransferStagingStore(
            rootURL: root,
            quotaBytes: 1,
            minimumFreeSpaceBytes: 0
        )
        await #expect(throws: TransferProtocolError.limitExceeded("staging quota")) {
            _ = try await store.prepare(
                transferID: UUID(),
                descriptor: descriptor,
                resume: nil
            )
        }
    }

    @Test("cancel cleanup removes only named transfer")
    func cleanupIsScoped() async throws {
        let context = try StagingSecurityContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try await context.store.prepare(
            transferID: context.transferID,
            descriptor: context.descriptor,
            resume: nil
        )
        try await context.store.cleanup(transferID: context.transferID)
        #expect(!(await context.store.recoveryStatuses().keys.contains(context.transferID)))
        #expect(!FileManager.default.fileExists(atPath: context.transferDirectory.path))
    }

    private func attachmentManifest(originalCount: Int) -> TransferManifest {
        let patientID = UUID()
        let patientEntityID = patientID
        let recordID = UUID()
        let attachmentID = UUID()
        let entities: [TransferEntityDescriptor] = [
            .init(
                kind: .patient,
                entityID: patientEntityID,
                patientID: patientID,
                payloadFileID: UUID(),
                revision: 1
            ),
            .init(
                kind: .medicalRecord,
                entityID: recordID,
                patientID: patientID,
                payloadFileID: UUID(),
                revision: 1
            ),
            .init(
                kind: .attachment,
                entityID: attachmentID,
                patientID: patientID,
                payloadFileID: UUID(),
                revision: 1
            )
        ]
        var files = entities.map { entity in
            TransferFileDescriptor(
                kind: .domainSnapshot,
                fileID: entity.payloadFileID,
                patientID: patientID,
                relativePath:
                    "members/\(patientID.uuidString.lowercased())/\(entity.payloadFileID).json",
                byteCount: 1,
                sha256: String(repeating: "a", count: 64)
            )
        }
        for index in 0..<originalCount {
            files.append(
                TransferFileDescriptor(
                    kind: .originalAttachment,
                    fileID: UUID(),
                    patientID: patientID,
                    ownerAttachmentID: attachmentID,
                    relativePath:
                        "members/\(patientID.uuidString.lowercased())/original-\(index).bin",
                    byteCount: 1,
                    sha256: String(repeating: "b", count: 64)
                )
            )
        }
        return TransferManifest(
            transferID: UUID(),
            scope: .singlePatient(patientID),
            createdAtUTC: "2026-07-31T00:00:00Z",
            capabilities: [
                TransferCapability(identifier: "domain.json", version: 1)
            ],
            preview: .init(memberCount: 1, recordCount: 1, attachmentCount: 1),
            entities: entities,
            files: files
        )
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbySecurity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct StagingSecurityContext {
    let root: URL
    let transferID = UUID()
    let store: TransferStagingStore
    let descriptor: ValidatedTransferFileDescriptor

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyCleanup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let patientID = UUID()
        descriptor = try TransferFileDescriptor(
            kind: .originalAttachment,
            fileID: UUID(),
            patientID: patientID,
            ownerAttachmentID: UUID(),
            relativePath: "members/\(patientID.uuidString.lowercased())/source.bin",
            byteCount: 1,
            sha256: String(repeating: "a", count: 64)
        ).validated()
        store = try TransferStagingStore(rootURL: root, minimumFreeSpaceBytes: 0)
    }

    var transferDirectory: URL {
        root.appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
    }
}
