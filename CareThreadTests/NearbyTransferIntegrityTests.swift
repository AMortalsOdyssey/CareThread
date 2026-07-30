import CryptoKit
import Foundation
import Testing
@testable import CareThread

struct NearbyTransferIntegrityTests {
    @Test("清单、domain graph 与所有暂存文件通过后才返回 VerifiedTransfer")
    func allIntegrityChecksProduceVerifiedTransfer() async throws {
        let fixture = TransferTestFixture.all()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await stageTransferFixture(fixture, sessions: sessions, rootURL: root)
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)

        let verified = try await TransferIntegrityVerifier.verifyCommitReadiness(
            sealedManifest: sealed,
            session: sessions.receiver,
            stagingStore: store
        )
        #expect(verified.plan.transferID == fixture.manifest.transferID)
        #expect(verified.plan.scope == .allPatients)
        #expect(verified.plan.patientIDs == Set(fixture.patientIDs))
    }

    @Test("缺少任一 verifier-owned 暂存文件不返回 token")
    func missingFileRejectsCommitReadiness() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStagingStore(rootURL: root)
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        await #expect(throws: TransferProtocolError.self) {
            _ = try await TransferIntegrityVerifier.verifyCommitReadiness(
                sealedManifest: sealed,
                session: sessions.receiver,
                stagingStore: store
            )
        }
    }

    @Test("同字节数篡改即使曾标记 verified 仍被 SHA256 发现")
    func sameSizeTamperRejectsCommitReadiness() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await stageTransferFixture(fixture, sessions: sessions, rootURL: root)
        let file = fixture.manifest.files[0]
        let stagedURL = root
            .appendingPathComponent("staging")
            .appendingPathComponent(fixture.manifest.transferID.uuidString.lowercased())
            .appendingPathComponent("files")
            .appendingPathComponent(file.fileID.uuidString.lowercased())
            .appendingPathExtension("partial")
        try Data(repeating: 0xFF, count: Int(file.byteCount)).write(to: stagedURL)
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        await #expect(throws: TransferProtocolError.fileHashMismatch(fileID: file.fileID)) {
            _ = try await TransferIntegrityVerifier.verifyCommitReadiness(
                sealedManifest: sealed,
                session: sessions.receiver,
                stagingStore: store
            )
        }
    }

    @Test("domainSnapshot 不是版本化 JSON 而是任意字符串时拒绝")
    func arbitraryDomainStringIsRejected() async throws {
        let base = TransferTestFixture.single()
        let attacked = replacingPayload(
            in: base,
            with: Data("not-json-domain".utf8)
        )
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: attacked.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await stageTransferFixture(attacked, sessions: sessions, rootURL: root)
        let sealed = try await sessions.sender.sealOutgoingManifest(attacked.manifest)
        await #expect(throws: TransferProtocolError.invalidManifest("malformed JSON")) {
            _ = try await TransferIntegrityVerifier.verifyCommitReadiness(
                sealedManifest: sealed,
                session: sessions.receiver,
                stagingStore: store
            )
        }
    }

    @Test("payload patientID 与 descriptor 不同即拒绝跨成员注入")
    func crossPatientPayloadIsRejected() async throws {
        let base = TransferTestFixture.single()
        let entity = base.manifest.entities[0]
        let payload = try StableJSON.encode(
            TransferDomainEnvelopeV1(
                kind: entity.kind,
                entityID: entity.entityID,
                patientID: UUID(),
                revision: entity.revision,
                fields: ["displayName": "攻击数据"]
            )
        )
        let attacked = replacingPayload(in: base, with: payload)
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: attacked.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await stageTransferFixture(attacked, sessions: sessions, rootURL: root)
        let sealed = try await sessions.sender.sealOutgoingManifest(attacked.manifest)
        await #expect(throws: TransferProtocolError.invalidManifest("descriptor payload mismatch")) {
            _ = try await TransferIntegrityVerifier.verifyCommitReadiness(
                sealedManifest: sealed,
                session: sessions.receiver,
                stagingStore: store
            )
        }
    }

    @Test("接收端提交后生成认证回执，发送端验证后才可完成")
    func authenticatedCommitReceiptCompletesSender() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await stageTransferFixture(fixture, sessions: sessions, rootURL: root)
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        let verified = try await TransferIntegrityVerifier.verifyCommitReadiness(
            sealedManifest: sealed,
            session: sessions.receiver,
            stagingStore: store
        )
        let resultDigest = String(repeating: "a", count: 64)
        let receipt = try await TransferCommitCoordinator.commitOnReceiver(
            verified,
            stagingStore: store,
            session: sessions.receiver,
            committedAtUTC: "2026-07-31T01:00:00Z"
        ) { token in
            #expect(token.plan.transferID == fixture.manifest.transferID)
            return resultDigest
        }
        let proof = try await TransferCommitCoordinator.verifyOnSender(
            receipt,
            expectedTransferID: fixture.manifest.transferID,
            expectedManifestSHA256: sealed.manifestSHA256,
            session: sessions.sender
        )
        #expect(proof.resultSHA256 == resultDigest)

        var machine = try senderAwaitingReceipt()
        try machine.acceptVerifiedCommitReceipt(proof)
        #expect(machine.state == .completed)
    }

    @Test("篡改 CommitReceipt MAC 后发送端不能完成")
    func tamperedCommitReceiptIsRejected() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let receipt = TransferCommitReceipt(
            transferID: fixture.manifest.transferID,
            manifestSHA256: String(repeating: "a", count: 64),
            resultSHA256: String(repeating: "b", count: 64),
            committedAtUTC: "2026-07-31T01:00:00Z",
            authenticationTag: Data(repeating: 0, count: 32)
        )
        await #expect(throws: TransferProtocolError.invalidCommitReceipt) {
            _ = try await TransferCommitCoordinator.verifyOnSender(
                receipt,
                expectedTransferID: receipt.transferID,
                expectedManifestSHA256: receipt.manifestSHA256,
                session: sessions.sender
            )
        }
    }

    @Test("已提交 result 与认证 receipt 重启后幂等恢复且不重复导入")
    func committedReceiptSurvivesRestartIdempotently() async throws {
        let fixture = TransferTestFixture.single()
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await stageTransferFixture(
            fixture,
            sessions: sessions,
            rootURL: root
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        let verified = try await TransferIntegrityVerifier.verifyCommitReadiness(
            sealedManifest: sealed,
            session: sessions.receiver,
            stagingStore: store
        )
        let counter = CommitImportCounter()
        let first = try await TransferCommitCoordinator.commitOnReceiver(
            verified,
            stagingStore: store,
            session: sessions.receiver,
            committedAtUTC: "2026-07-31T01:00:00Z"
        ) { _ in
            await counter.invoke()
        }
        let reopened = try TransferStagingStore(
            rootURL: root.appendingPathComponent("staging", isDirectory: true)
        )
        let recoverySessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID,
            sessionID: UUID(
                uuidString: "90000000-0000-0000-0000-000000000010"
            )!
        )
        let recovered = try await TransferCommitCoordinator.commitOnReceiver(
            verified,
            stagingStore: reopened,
            session: recoverySessions.receiver,
            committedAtUTC: "2026-07-31T02:00:00Z"
        ) { _ in
            await counter.invoke()
        }
        #expect(recovered.resultSHA256 == first.resultSHA256)
        #expect(recovered.authenticationTag != first.authenticationTag)
        #expect(await counter.value == 1)
        _ = try await TransferCommitCoordinator.verifyOnSender(
            recovered,
            expectedTransferID: fixture.manifest.transferID,
            expectedManifestSHA256: sealed.manifestSHA256,
            session: recoverySessions.sender
        )
    }

    @Test("Attachment、Record 与 original 双向闭包通过")
    func completeAttachmentGraphPasses() async throws {
        let verified = try await verifyFixture(.attachmentGraph())
        #expect(verified.plan.entityCount == 3)
        #expect(verified.plan.fileCount == 4)
    }

    @Test("Attachment 缺少 Record reference 被拒绝")
    func missingAttachmentRecordReferenceFails() async throws {
        await #expect(throws: TransferProtocolError.self) {
            _ = try await verifyFixture(
                .attachmentGraph(attack: .missingRecordReference)
            )
        }
    }

    @Test("Attachment 掉包为未声明 originalFileID 被拒绝")
    func swappedAttachmentOriginalFails() async throws {
        await #expect(throws: TransferProtocolError.self) {
            _ = try await verifyFixture(
                .attachmentGraph(attack: .swappedOriginalFile)
            )
        }
    }

    @Test("未被 entity descriptor 认领的 domain payload 被拒绝")
    func orphanDomainPayloadFails() async throws {
        await #expect(throws: TransferProtocolError.self) {
            _ = try await verifyFixture(
                .attachmentGraph(attack: .orphanDomainPayload)
            )
        }
    }

    private func replacingPayload(
        in fixture: TransferTestFixture,
        with payload: Data
    ) -> TransferTestFixture {
        let oldFile = fixture.manifest.files[0]
        let newFile = TransferFileDescriptor(
            kind: oldFile.kind,
            fileID: oldFile.fileID,
            patientID: oldFile.patientID,
            relativePath: oldFile.relativePath,
            byteCount: Int64(payload.count),
            sha256: Data(SHA256.hash(data: payload)).testHex
        )
        let manifest = TransferManifest(
            transferID: fixture.manifest.transferID,
            scope: fixture.manifest.scope,
            createdAtUTC: fixture.manifest.createdAtUTC,
            capabilities: fixture.manifest.capabilities,
            preview: fixture.manifest.preview,
            entities: fixture.manifest.entities,
            files: [newFile]
        )
        return TransferTestFixture(
            manifest: manifest,
            patientIDs: fixture.patientIDs,
            payloads: [newFile.fileID: payload]
        )
    }

    private func verifyFixture(
        _ fixture: TransferTestFixture
    ) async throws -> VerifiedTransfer {
        let sessions = try await AuthorizedTransferSessions.make(
            transferID: fixture.manifest.transferID
        )
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await stageTransferFixture(
            fixture,
            sessions: sessions,
            rootURL: root
        )
        let sealed = try await sessions.sender.sealOutgoingManifest(fixture.manifest)
        return try await TransferIntegrityVerifier.verifyCommitReadiness(
            sealedManifest: sealed,
            session: sessions.receiver,
            stagingStore: store
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyIntegrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func senderAwaitingReceipt() throws -> TransferStateMachine {
        var machine = TransferStateMachine(role: .sender)
        try machine.transition(to: .discovering)
        try machine.transition(to: .connecting)
        try machine.transition(to: .pairing)
        try machine.transition(to: .awaitingPairingConfirmation)
        try machine.transition(to: .negotiating)
        try machine.transition(
            to: .transferring(try TransferProgress(completedBytes: 0, totalBytes: 0))
        )
        try machine.transition(to: .verifying)
        try machine.transition(to: .awaitingCommitReceipt)
        return machine
    }
}

private actor CommitImportCounter {
    private(set) var value = 0

    func invoke() -> String {
        value += 1
        return String(repeating: "d", count: 64)
    }
}
