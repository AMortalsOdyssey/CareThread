import Foundation
import Testing
@testable import CareThread

struct NearbyTransferManifestTests {
    @Test("单成员清单通过精确范围与计数校验")
    func singlePatientManifestValidates() throws {
        let fixture = TransferTestFixture.single()
        try fixture.manifest.validate()
        #expect(fixture.manifest.scope == .singlePatient(fixture.patientIDs[0]))
        #expect(fixture.manifest.preview.memberCount == 1)
        #expect(fixture.manifest.preview.recordCount == 0)
    }

    @Test("全部成员清单允许多个隔离成员")
    func allPatientManifestValidates() throws {
        let fixture = TransferTestFixture.all()
        try fixture.manifest.validate()
        #expect(Set(fixture.manifest.entities.map(\.patientID)) == Set(fixture.patientIDs))
    }

    @Test("清单输入顺序不同仍得到稳定 JSON")
    func canonicalEncodingIsStable() throws {
        let fixture = TransferTestFixture.all()
        let reversed = TransferManifest(
            transferID: fixture.manifest.transferID,
            scope: fixture.manifest.scope,
            createdAtUTC: fixture.manifest.createdAtUTC,
            capabilities: fixture.manifest.capabilities.reversed(),
            preview: fixture.manifest.preview,
            entities: fixture.manifest.entities.reversed(),
            files: fixture.manifest.files.reversed()
        )
        #expect(try StableJSON.encode(fixture.manifest) == StableJSON.encode(reversed))
    }

    @Test("严格解码拒绝未知字段")
    func strictDecodeRejectsUnknownKey() throws {
        let data = try StableJSON.encode(TransferTestFixture.single().manifest)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["attacker"] = "ignored-by-default-decoder"
        let attacked = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: TransferProtocolError.self) {
            try TransferManifest.decodeAndValidate(from: attacked)
        }
    }

    @Test("接收端拒绝更高协议版本")
    func incompatibleVersionIsRejected() {
        let fixture = TransferTestFixture.single(protocolVersion: 2, minimumReceiverVersion: 2)
        #expect(throws: TransferProtocolError.self) {
            try fixture.manifest.validate(receiverProtocolVersion: 1)
        }
    }

    @Test("单成员清单混入其他成员即拒绝")
    func scopeLeakIsRejected() {
        let base = TransferTestFixture.all()
        let invalid = TransferManifest(
            transferID: base.manifest.transferID,
            scope: .singlePatient(base.patientIDs[0]),
            createdAtUTC: base.manifest.createdAtUTC,
            capabilities: base.manifest.capabilities,
            preview: TransferPreviewCounts(memberCount: 1, recordCount: 0, attachmentCount: 0),
            entities: base.manifest.entities,
            files: base.manifest.files
        )
        #expect(throws: TransferProtocolError.scopeViolation) {
            try invalid.validate()
        }
    }

    @Test("现有成员加导入成员超过 20 人会预检失败")
    func existingPlusImportedMemberLimitIsEnforced() {
        let fixture = TransferTestFixture.single()
        let existing = Set((0..<20).map { _ in UUID() })
        #expect(throws: TransferProtocolError.limitExceeded("existing plus imported members")) {
            try fixture.manifest.validate(existingPatientIDs: existing)
        }
    }

    @Test("预览计数不能由发送端伪造")
    func previewCountsAreRecomputed() {
        let fixture = TransferTestFixture.single()
        let invalid = TransferManifest(
            transferID: fixture.manifest.transferID,
            scope: fixture.manifest.scope,
            createdAtUTC: fixture.manifest.createdAtUTC,
            capabilities: fixture.manifest.capabilities,
            preview: TransferPreviewCounts(memberCount: 1, recordCount: 99, attachmentCount: 0),
            entities: fixture.manifest.entities,
            files: fixture.manifest.files
        )
        #expect(throws: TransferProtocolError.invalidManifest("preview count mismatch")) {
            try invalid.validate()
        }
    }

    @Test("分块大小只能是固定 64KiB")
    func variableChunkSizeIsRejected() {
        let fixture = TransferTestFixture.single()
        let file = fixture.manifest.files[0]
        let invalid = TransferFileDescriptor(
            kind: file.kind,
            fileID: file.fileID,
            patientID: file.patientID,
            relativePath: file.relativePath,
            byteCount: file.byteCount,
            sha256: file.sha256,
            chunkSize: 1
        )
        #expect(throws: TransferProtocolError.invalidManifest("chunk size must be 64KiB")) {
            try invalid.validated()
        }
    }
}
