import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import CareThread

@Suite("NearbySync application transfer")
struct NearbySyncTests {
    @Test("stable domain id is deterministic")
    func stableIDDeterministic() {
        let id = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        #expect(
            NearbySyncStableID.derive(id, label: "domain:patient")
                == NearbySyncStableID.derive(id, label: "domain:patient")
        )
    }

    @Test("stable domain id separates entity kinds")
    func stableIDSeparatesLabels() {
        let id = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        #expect(
            NearbySyncStableID.derive(id, label: "domain:patient")
                != NearbySyncStableID.derive(id, label: "domain:attachment")
        )
    }

    @Test("stable domain id has UUID v5 marker")
    func stableIDVersionMarker() {
        let value = NearbySyncStableID.derive(UUID(), label: "domain:test")
        let versionNibble = withUnsafeBytes(of: value.uuid) { Int($0[6] >> 4) }
        #expect(versionNibble == 5)
    }

    @Test("app contract is exactly full-domain v1")
    func capabilityIsPinned() {
        #expect(NearbySyncContract.capability.identifier == "carethread.full-domain")
        #expect(NearbySyncContract.capability.version == 1)
    }

    @Test("application transfer cap is 4 GiB")
    func transferLimitIsFourGiB() {
        #expect(
            NearbySyncContract.maximumTransferBytes
                == Int64(4 * 1_024 * 1_024 * 1_024)
        )
    }

    @Test("payload rejects a mismatched entity id")
    func payloadRejectsMismatchedID() throws {
        let id = UUID()
        let patient = Patient(id: id, displayName: "虚构成员")
        let snapshot = NearbySyncSnapshotFactory.make(patient)
        let data = try snapshot.payload.encoded()
        let envelope = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )
        #expect(throws: NearbySyncError.payloadMismatch) {
            let value = try StableJSON.decode(
                NearbySyncEntityPayloadV1.self,
                from: data
            )
            try value.validate(
                kind: envelope.kind,
                entityID: UUID(),
                patientID: envelope.patientID
            )
        }
    }

    @Test("patient portable payload round-trips")
    func patientPayloadRoundTrip() throws {
        let patient = Patient(displayName: "虚构成员")
        let snapshot = NearbySyncSnapshotFactory.make(patient)
        let envelope = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )
        let decoded = try NearbySyncEntityPayloadV1.decode(
            try #require(envelope.portablePayload),
            envelope: envelope
        )
        #expect(decoded.patient?.editable.displayName == "虚构成员")
    }

    @Test("portable payload is carried as canonical base64")
    func portablePayloadIsCanonicalBase64() throws {
        let snapshot = NearbySyncSnapshotFactory.make(
            Patient(displayName: "虚构成员")
        )
        let envelope = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )
        let data = try #require(envelope.portablePayload)
        #expect(data.base64EncodedString().isEmpty == false)
    }

    @Test("non-canonical base64 is rejected")
    func nonCanonicalBase64Rejected() throws {
        let patientID = UUID()
        let data = try StableJSON.encode(
            TransferDomainEnvelopeV1(
                kind: .patient,
                entityID: patientID,
                patientID: patientID,
                revision: 0,
                fields: [
                    "displayName": "虚构",
                    "portablePayloadBase64": "YQ==\n"
                ]
            )
        )
        #expect(throws: TransferProtocolError.self) {
            _ = try TransferDomainEnvelopeV1.decodeStrict(from: data)
        }
    }

    @Test("payload over 180 KiB is safely blocked")
    func oversizedPayloadBlocked() {
        let id = UUID()
        let patient = Patient(
            id: id,
            displayName: String(repeating: "测", count: 70_000)
        )
        let snapshot = NearbySyncSnapshotFactory.make(patient)
        #expect(throws: NearbySyncError.self) {
            _ = try snapshot.envelopeData()
        }
    }

    @Test("bootstrap wire message round-trips")
    func bootstrapWireRoundTrip() throws {
        let sessionID = UUID()
        let transferID = UUID()
        let encoded = try NearbySyncWireCodec.encode(
            .bootstrap(
                .init(
                    protocolVersion: 1,
                    sessionID: sessionID,
                    transferID: transferID,
                    senderAlias: "ct-1234567890ab"
                )
            )
        )
        guard case let .bootstrap(value) = try NearbySyncWireCodec.decode(encoded.data)
        else {
            Issue.record("wrong wire type")
            return
        }
        #expect(value.sessionID == sessionID)
        #expect(value.transferID == transferID)
    }

    @Test("bootstrap acknowledgement round-trips")
    func bootstrapAckRoundTrip() throws {
        let value = NearbySyncBootstrapAcknowledgement(
            protocolVersion: 1,
            sessionID: UUID(),
            transferID: UUID(),
            receiverAlias: "ct-abcdef123456"
        )
        let encoded = try NearbySyncWireCodec.encode(
            .bootstrapAcknowledgement(value)
        )
        guard case let .bootstrapAcknowledgement(decoded) =
            try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
        #expect(decoded.receiverAlias == value.receiverAlias)
    }

    @Test("hello wire message stays in handshake category")
    func helloUsesHandshakeCategory() async throws {
        let session = try NearbyTransferSession(
            role: .sender,
            transferID: UUID()
        )
        let encoded = try NearbySyncWireCodec.encode(
            .hello(await session.localHello())
        )
        #expect(encoded.category == .handshake)
        guard case .hello = try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
    }

    @Test("manifest decision round-trips without member names")
    func manifestDecisionRoundTrip() throws {
        let value = NearbySyncManifestDecision(
            transferID: UUID(),
            accepted: true,
            receiverAlias: "ct-abcdef123456",
            alreadyCommitted: false
        )
        let encoded = try NearbySyncWireCodec.encode(.manifestDecision(value))
        guard case let .manifestDecision(decoded) =
            try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
        #expect(decoded.receiverAlias.hasPrefix("ct-"))
        #expect(decoded.accepted)
    }

    @Test("resume query round-trips")
    func resumeQueryRoundTrip() throws {
        let value = NearbySyncResumeQuery(transferID: UUID(), fileID: UUID())
        let encoded = try NearbySyncWireCodec.encode(.resumeQuery(value))
        guard case let .resumeQuery(decoded) =
            try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
        #expect(decoded.fileID == value.fileID)
    }

    @Test("resume response round-trips")
    func resumeResponseRoundTrip() throws {
        let transferID = UUID()
        let patientID = UUID()
        let descriptor = try TransferFileDescriptor(
            kind: .domainSnapshot,
            fileID: UUID(),
            patientID: patientID,
            relativePath: "members/\(patientID.uuidString.lowercased())/a.json",
            byteCount: 1,
            sha256: String(repeating: "a", count: 64)
        ).validated()
        let state = TransferResumeState(
            transferID: transferID,
            descriptor: descriptor
        )
        let encoded = try NearbySyncWireCodec.encode(
            .resumeResponse(.init(transferID: transferID, state: state))
        )
        guard case let .resumeResponse(decoded) =
            try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
        #expect(decoded.state.fileID == descriptor.fileID)
    }

    @Test("chunk ACK round-trips")
    func chunkAckRoundTrip() throws {
        let value = NearbySyncChunkAcknowledgement(
            transferID: UUID(),
            fileID: UUID(),
            sequence: 3,
            nextOffset: 64
        )
        let encoded = try NearbySyncWireCodec.encode(
            .chunkAcknowledgement(value)
        )
        guard case let .chunkAcknowledgement(decoded) =
            try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
        #expect(decoded == value)
    }

    @Test("transfer-finished round-trips")
    func transferFinishedRoundTrip() throws {
        let id = UUID()
        let encoded = try NearbySyncWireCodec.encode(
            .transferFinished(.init(transferID: id))
        )
        guard case let .transferFinished(decoded) =
            try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
        #expect(decoded.transferID == id)
    }

    @Test("cancel message round-trips")
    func cancelRoundTrip() throws {
        let id = UUID()
        let encoded = try NearbySyncWireCodec.encode(
            .cancel(.init(transferID: id, reason: "user"))
        )
        guard case let .cancel(decoded) =
            try NearbySyncWireCodec.decode(encoded.data) else {
            Issue.record("wrong wire type")
            return
        }
        #expect(decoded.transferID == id)
    }

    @Test("unknown application frame is rejected")
    func unknownWireRejected() {
        #expect(throws: TransferProtocolError.self) {
            _ = try NearbySyncWireCodec.decode(Data("internet".utf8))
        }
    }

    @Test("UUID policy inserts unknown entities")
    func conflictPolicyInsert() throws {
        let id = UUID()
        let hash = String(repeating: "a", count: 64)
        let result = try TransferUUIDConflictPolicyV1.preflight(
            incoming: [id: hash],
            existing: [:]
        )
        #expect(result[id] == .insert)
    }

    @Test("UUID policy accepts an identical replay")
    func conflictPolicyReplay() throws {
        let id = UUID()
        let hash = String(repeating: "b", count: 64)
        let result = try TransferUUIDConflictPolicyV1.preflight(
            incoming: [id: hash],
            existing: [id: hash]
        )
        #expect(result[id] == .idempotentExisting)
    }

    @Test("UUID policy blocks a different payload")
    func conflictPolicyMismatch() {
        let id = UUID()
        #expect(throws: TransferProtocolError.uuidConflict(id)) {
            _ = try TransferUUIDConflictPolicyV1.preflight(
                incoming: [id: String(repeating: "a", count: 64)],
                existing: [id: String(repeating: "b", count: 64)]
            )
        }
    }

    @Test("single-member exporter contains exactly one patient")
    @MainActor
    func singleExporterScope() throws {
        let env = try NearbySyncTestEnvironment.make()
        let first = try env.seedFullGraph(index: 1)
        _ = try env.seedFullGraph(index: 2)
        let package = try NearbySyncExporter(
            context: env.context,
            vault: env.vault,
            temporaryRoot: env.root.appendingPathComponent("Export")
        ).prepare(scope: .singlePatient(first.patientID))
        #expect(package.manifest.preview.memberCount == 1)
        #expect(Set(package.manifest.entities.map(\.patientID)) == [first.patientID])
        package.cleanup()
    }

    @Test("all-member exporter contains each selected patient")
    @MainActor
    func allExporterScope() throws {
        let env = try NearbySyncTestEnvironment.make()
        _ = try env.seedFullGraph(index: 3)
        _ = try env.seedFullGraph(index: 4)
        let package = try NearbySyncExporter(
            context: env.context,
            vault: env.vault,
            temporaryRoot: env.root.appendingPathComponent("Export")
        ).prepare(scope: .allPatients)
        #expect(package.manifest.preview.memberCount == 2)
        #expect(package.manifest.preview.recordCount == 2)
        #expect(package.manifest.preview.attachmentCount == 2)
        package.cleanup()
    }

    @Test("export preview counts domain and original files")
    @MainActor
    func exporterPreviewCountsFiles() throws {
        let env = try NearbySyncTestEnvironment.make()
        let ids = try env.seedFullGraph(index: 5)
        let preview = try NearbySyncExporter(
            context: env.context,
            vault: env.vault
        ).preview(scope: .singlePatient(ids.patientID))
        #expect(preview.entityCount == 11)
        #expect(preview.fileCount == 12)
        #expect(preview.totalByteCount > 0)
    }

    @Test("exporter blocks a missing immutable original")
    @MainActor
    func exporterBlocksMissingOriginal() throws {
        let env = try NearbySyncTestEnvironment.make()
        let ids = try env.seedFullGraph(index: 6)
        let attachment = try #require(
            try env.context.fetch(FetchDescriptor<Attachment>()).first
        )
        try FileManager.default.removeItem(
            at: try env.vault.url(for: attachment.originalRelativePath)
        )
        #expect(throws: NearbySyncError.missingOriginal(ids.attachmentID!)) {
            _ = try NearbySyncExporter(
                context: env.context,
                vault: env.vault
            ).prepare(scope: .singlePatient(ids.patientID))
        }
    }

    @Test("exporter blocks an original whose hash changed")
    @MainActor
    func exporterBlocksChangedOriginal() throws {
        let env = try NearbySyncTestEnvironment.make()
        let ids = try env.seedFullGraph(index: 7)
        let attachment = try #require(
            try env.context.fetch(FetchDescriptor<Attachment>()).first
        )
        try Data("tampered".utf8).write(
            to: try env.vault.url(for: attachment.originalRelativePath)
        )
        #expect(throws: NearbySyncError.originalChanged(ids.attachmentID!)) {
            _ = try NearbySyncExporter(
                context: env.context,
                vault: env.vault
            ).prepare(scope: .singlePatient(ids.patientID))
        }
    }

    @Test("exporter blocks an unattached Attachment")
    @MainActor
    func exporterBlocksOrphanAttachment() throws {
        let env = try NearbySyncTestEnvironment.make()
        let ids = try env.seedFullGraph(index: 8, includeAttachment: false)
        let orphan = Attachment(
            patientId: ids.patientID,
            fileName: "orphan.jpg",
            kind: .image,
            pageIndex: 0
        )
        env.context.insert(orphan)
        try env.context.save()
        #expect(throws: NearbySyncError.self) {
            _ = try NearbySyncExporter(
                context: env.context,
                vault: env.vault
            ).prepare(scope: .singlePatient(ids.patientID))
        }
    }

    @Test("cross-member assignment audit is owned by the assigned member")
    @MainActor
    func exporterScopesCrossMemberAuditToAssignedMember() throws {
        let env = try NearbySyncTestEnvironment.make()
        let one = try env.seedFullGraph(index: 9, includeAttachment: false)
        let two = try env.seedFullGraph(index: 10, includeAttachment: false)
        let auditID = UUID()
        env.context.insert(
            RecordAssignmentAudit(
                id: auditID,
                capturedForPatientId: one.patientID,
                assignedPatientId: two.patientID,
                recordId: two.recordID,
                detectedName: nil,
                outcome: .mismatch,
                decision: .switchedMember,
                engineIdentifier: "test"
            )
        )
        try env.context.save()

        let exporter = NearbySyncExporter(
            context: env.context,
            vault: env.vault,
            temporaryRoot: env.root.appendingPathComponent("Export")
        )
        let single = try exporter.prepare(scope: .singlePatient(two.patientID))
        let patientEntities = single.manifest.entities.filter { $0.kind == .patient }
        let crossAudit = try #require(
            single.manifest.entities.first { $0.entityID == auditID }
        )
        #expect(patientEntities.map(\.entityID) == [two.patientID])
        #expect(Set(single.manifest.entities.map(\.patientID)) == [two.patientID])
        #expect(crossAudit.patientID == two.patientID)
        #expect(!single.manifest.entities.contains { $0.entityID == one.patientID })
        single.cleanup()

        let all = try exporter.prepare(scope: .allPatients)
        #expect(all.manifest.preview.memberCount == 2)
        #expect(all.manifest.entities.contains { $0.entityID == auditID })
        all.cleanup()
    }

    @Test("assignment audit payload rejects an assigned-member mismatch")
    func assignmentAuditPayloadRejectsMemberTamper() throws {
        let capturedID = UUID()
        let assignedID = UUID()
        let recordID = UUID()
        let audit = RecordAssignmentAudit(
            capturedForPatientId: capturedID,
            assignedPatientId: assignedID,
            recordId: recordID,
            detectedName: "虚构姓名",
            outcome: .mismatch,
            decision: .switchedMember,
            engineIdentifier: "test.offline"
        )
        let snapshot = try NearbySyncSnapshotFactory.make(audit)
        let envelope = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )
        let body = try #require(snapshot.payload.assignmentAudit)
        let tampered = NearbySyncEntityPayloadV1(
            kind: .assignmentAudit,
            entityID: snapshot.entityID,
            patientID: snapshot.patientID,
            assignmentAudit: .init(
                capturedForPatientID: body.capturedForPatientID,
                assignedPatientID: UUID(),
                draftID: body.draftID,
                recordID: body.recordID,
                detectedName: body.detectedName,
                outcome: body.outcome,
                decision: body.decision,
                overrideReason: body.overrideReason,
                engineIdentifier: body.engineIdentifier,
                engineVersion: body.engineVersion,
                createdAt: body.createdAt
            )
        )

        #expect(throws: NearbySyncError.payloadMismatch) {
            _ = try NearbySyncEntityPayloadV1.decode(
                try tampered.encoded(),
                envelope: envelope
            )
        }
    }

    @Test("assignment audit payload rejects a record-body mismatch")
    func assignmentAuditPayloadRejectsRecordTamper() throws {
        let audit = RecordAssignmentAudit(
            capturedForPatientId: UUID(),
            assignedPatientId: UUID(),
            recordId: UUID(),
            detectedName: "虚构姓名",
            outcome: .mismatch,
            decision: .switchedMember,
            engineIdentifier: "test.offline"
        )
        let snapshot = try NearbySyncSnapshotFactory.make(audit)
        let envelope = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )
        let body = try #require(snapshot.payload.assignmentAudit)
        let tampered = NearbySyncEntityPayloadV1(
            kind: .assignmentAudit,
            entityID: snapshot.entityID,
            patientID: snapshot.patientID,
            assignmentAudit: .init(
                capturedForPatientID: body.capturedForPatientID,
                assignedPatientID: body.assignedPatientID,
                draftID: body.draftID,
                recordID: UUID(),
                detectedName: body.detectedName,
                outcome: body.outcome,
                decision: body.decision,
                overrideReason: body.overrideReason,
                engineIdentifier: body.engineIdentifier,
                engineVersion: body.engineVersion,
                createdAt: body.createdAt
            )
        )

        #expect(throws: NearbySyncError.payloadMismatch) {
            _ = try NearbySyncEntityPayloadV1.decode(
                try tampered.encoded(),
                envelope: envelope
            )
        }
    }

    @Test("assignment audit payload rejects a record/reference mismatch")
    func assignmentAuditPayloadRejectsReferenceTamper() throws {
        let capturedID = UUID()
        let assignedID = UUID()
        let recordID = UUID()
        let audit = RecordAssignmentAudit(
            capturedForPatientId: capturedID,
            assignedPatientId: assignedID,
            recordId: recordID,
            detectedName: "虚构姓名",
            outcome: .mismatch,
            decision: .switchedMember,
            engineIdentifier: "test.offline"
        )
        let snapshot = try NearbySyncSnapshotFactory.make(audit)
        let original = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )
        let tamperedEnvelope = ValidatedTransferDomainEnvelopeV1(
            schemaVersion: original.schemaVersion,
            kind: original.kind,
            entityID: original.entityID,
            patientID: original.patientID,
            revision: original.revision,
            references: [
                .init(entityID: UUID(), kind: .medicalRecord)
            ],
            fields: original.fields,
            portablePayload: original.portablePayload
        )

        #expect(throws: NearbySyncError.payloadMismatch) {
            _ = try NearbySyncEntityPayloadV1.decode(
                try snapshot.payload.encoded(),
                envelope: tamperedEnvelope
            )
        }
    }

    @Test("medication source record body must match its envelope reference")
    @MainActor
    func medicationSourceRecordTamperRejected() throws {
        let environment = try NearbySyncTestEnvironment.make()
        _ = try environment.seedFullGraph(index: 31, includeAttachment: false)
        let medication = try #require(
            environment.context.fetch(FetchDescriptor<Medication>()).first
        )
        let snapshot = NearbySyncSnapshotFactory.make(medication)
        let body = try #require(snapshot.payload.medication)
        let tampered = NearbySyncEntityPayloadV1(
            kind: .medication,
            entityID: snapshot.entityID,
            patientID: snapshot.patientID,
            medication: .init(
                editable: body.editable,
                sourceRecordID: UUID(),
                previousVersionID: body.previousVersionID,
                createdAt: body.createdAt,
                contentRevision: body.contentRevision
            )
        )

        try expectRelationshipPayloadRejected(tampered, against: snapshot)
    }

    @Test("medical order record and generated follow-up must match references")
    @MainActor
    func medicalOrderForeignKeyTamperRejected() throws {
        let environment = try NearbySyncTestEnvironment.make()
        _ = try environment.seedFullGraph(index: 32, includeAttachment: false)
        let order = try #require(
            environment.context.fetch(FetchDescriptor<MedicalOrder>()).first
        )
        let snapshot = NearbySyncSnapshotFactory.make(order)
        let body = try #require(snapshot.payload.medicalOrder)
        let variants = [
            NearbySyncEntityPayloadV1(
                kind: .medicalOrder,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                medicalOrder: .init(
                    editable: body.editable,
                    sourceRecordID: UUID(),
                    generatedFollowUpID: body.generatedFollowUpID,
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            ),
            NearbySyncEntityPayloadV1(
                kind: .medicalOrder,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                medicalOrder: .init(
                    editable: body.editable,
                    sourceRecordID: body.sourceRecordID,
                    generatedFollowUpID: UUID(),
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            )
        ]

        for tampered in variants {
            try expectRelationshipPayloadRejected(tampered, against: snapshot)
        }
    }

    @Test("follow-up order, bring, compare and result links are canonical")
    @MainActor
    func followUpForeignKeyTamperRejected() throws {
        let environment = try NearbySyncTestEnvironment.make()
        _ = try environment.seedFullGraph(index: 33, includeAttachment: false)
        let followUp = try #require(
            environment.context.fetch(FetchDescriptor<FollowUp>()).first
        )
        let snapshot = NearbySyncSnapshotFactory.make(followUp)
        let body = try #require(snapshot.payload.followUp)
        var bringTamper = body.editable
        bringTamper.bringRecordIds = [UUID()]
        var compareTamper = body.editable
        compareTamper.compareRecordId = UUID()
        var resultTamper = body.editable
        resultTamper.resultRecordId = UUID()
        let variants = [
            NearbySyncEntityPayloadV1(
                kind: .followUp,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                followUp: .init(
                    editable: body.editable,
                    sourceOrderID: UUID(),
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            ),
            NearbySyncEntityPayloadV1(
                kind: .followUp,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                followUp: .init(
                    editable: bringTamper,
                    sourceOrderID: body.sourceOrderID,
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            ),
            NearbySyncEntityPayloadV1(
                kind: .followUp,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                followUp: .init(
                    editable: compareTamper,
                    sourceOrderID: body.sourceOrderID,
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            ),
            NearbySyncEntityPayloadV1(
                kind: .followUp,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                followUp: .init(
                    editable: resultTamper,
                    sourceOrderID: body.sourceOrderID,
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            )
        ]

        for tampered in variants {
            try expectRelationshipPayloadRejected(tampered, against: snapshot)
        }
    }

    @Test("reminder record, medication and follow-up links are canonical")
    @MainActor
    func reminderForeignKeyTamperRejected() throws {
        let environment = try NearbySyncTestEnvironment.make()
        _ = try environment.seedFullGraph(index: 34, includeAttachment: false)
        let reminder = try #require(
            environment.context.fetch(FetchDescriptor<ReminderSchedule>()).first
        )
        let snapshot = NearbySyncSnapshotFactory.make(reminder)
        let body = try #require(snapshot.payload.reminder)
        let variants = [
            NearbySyncEntityPayloadV1(
                kind: .reminder,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                reminder: .init(
                    editable: body.editable,
                    sourceRecordID: UUID(),
                    sourceMedicationID: body.sourceMedicationID,
                    sourceFollowUpID: body.sourceFollowUpID,
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            ),
            NearbySyncEntityPayloadV1(
                kind: .reminder,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                reminder: .init(
                    editable: body.editable,
                    sourceRecordID: body.sourceRecordID,
                    sourceMedicationID: UUID(),
                    sourceFollowUpID: body.sourceFollowUpID,
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            ),
            NearbySyncEntityPayloadV1(
                kind: .reminder,
                entityID: snapshot.entityID,
                patientID: snapshot.patientID,
                reminder: .init(
                    editable: body.editable,
                    sourceRecordID: body.sourceRecordID,
                    sourceMedicationID: body.sourceMedicationID,
                    sourceFollowUpID: UUID(),
                    createdAt: body.createdAt,
                    contentRevision: body.contentRevision
                )
            )
        ]

        for tampered in variants {
            try expectRelationshipPayloadRejected(tampered, against: snapshot)
        }
    }

    @Test("every foreign-key entity rejects a referenced target from another member")
    @MainActor
    func canonicalRelationshipPolicyRejectsCrossMemberTargets() throws {
        let environment = try NearbySyncTestEnvironment.make()
        let first = try environment.seedFullGraph(index: 35)
        let second = try environment.seedFullGraph(index: 36)
        let payload = try BackupExporter(
            context: environment.context,
            vault: environment.vault,
            temporaryRoot: environment.root.appendingPathComponent("Backup")
        ).collectPayload(scope: .singleMember(first.patientID))
        let targets = Dictionary(
            uniqueKeysWithValues: payload.entities.map {
                (
                    $0.entityID,
                    NearbySyncRelationshipTarget(
                        kind: $0.kind,
                        patientID: second.patientID
                    )
                )
            }
        )
        let revision = try #require(
            environment.context
                .fetch(FetchDescriptor<ContentRevision>())
                .first { $0.patientId == first.patientID }
        )
        let revisionSnapshot = try NearbySyncSnapshotFactory.make(revision)
        let related = try (payload.entities + [revisionSnapshot.payload]).filter {
            try !NearbySyncEntityRelationshipPolicy.canonicalReferences(for: $0)
                .isEmpty
        }

        #expect(
            Set(related.map(\.kind)).isSuperset(of: [
                .attachment, .medication, .medicalOrder, .followUp,
                .labMeasurement, .reminder, .assignmentAudit, .recordTag,
                .contentRevision
            ])
        )
        for entity in related {
            #expect(throws: NearbySyncError.self) {
                try NearbySyncEntityRelationshipPolicy.validateTargetClosure(
                    payload: entity,
                    targetsByID: targets
                )
            }
        }
    }

    @Test("legacy audit without assigned member falls back to captured owner")
    func legacyAssignmentAuditUsesCapturedOwner() throws {
        let capturedID = UUID()
        let recordID = UUID()
        let snapshot = try NearbySyncSnapshotFactory.make(
            RecordAssignmentAudit(
                capturedForPatientId: capturedID,
                assignedPatientId: nil,
                recordId: recordID,
                detectedName: nil,
                outcome: .noEvidence,
                decision: .acceptedWithoutNameEvidence,
                engineIdentifier: "legacy.test"
            )
        )
        let envelope = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )

        #expect(snapshot.patientID == capturedID)
        #expect(envelope.patientID == capturedID)
        #expect(snapshot.payload.assignmentAudit?.assignedPatientID == nil)
        #expect(snapshot.references == [
            .init(entityID: recordID, kind: .medicalRecord)
        ])
    }

    @Test("sender cancellation commits no receiver rows")
    @MainActor
    func senderCancellationIsAtomic() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 17)
        let harness = try makeNearbySyncHarness(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        defer { harness.package.cleanup() }

        await harness.senderCoordinator.cancel()
        do {
            _ = try await runNearbySyncHarness(harness)
            Issue.record("cancelled transfer unexpectedly completed")
        } catch {
            #expect(try receiver.context.fetchCount(FetchDescriptor<Patient>()) == 0)
            #expect(
                try receiver.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0
            )
        }
    }

    @Test("disconnection before handshake commits no receiver rows")
    @MainActor
    func disconnectionIsAtomic() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 18)
        let harness = try makeNearbySyncHarness(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        defer { harness.package.cleanup() }

        harness.receiverTransport.cancel()
        do {
            _ = try await runNearbySyncHarness(harness)
            Issue.record("disconnected transfer unexpectedly completed")
        } catch {
            #expect(try receiver.context.fetchCount(FetchDescriptor<Patient>()) == 0)
            #expect(
                try receiver.context.fetchCount(FetchDescriptor<Attachment>()) == 0
            )
        }
    }

    @Test("transit tamper is rejected before database commit")
    @MainActor
    func transitTamperIsAtomic() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 19)
        let harness = try makeNearbySyncHarness(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        defer { harness.package.cleanup() }

        let descriptor = try #require(
            harness.package.manifest.files.first { $0.kind == .domainSnapshot }
        )
        let url = try harness.package.fileURL(for: descriptor.fileID)
        var bytes = try Data(contentsOf: url)
        let index = bytes.index(
            bytes.startIndex,
            offsetBy: max(0, bytes.count / 2)
        )
        bytes[index] ^= 0x01
        try bytes.write(to: url, options: .atomic)

        do {
            _ = try await runNearbySyncHarness(harness)
            Issue.record("tampered transfer unexpectedly completed")
        } catch {
            #expect(try receiver.context.fetchCount(FetchDescriptor<Patient>()) == 0)
            #expect(
                try receiver.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0
            )
        }
    }

    @Test("UUID conflict rolls back the whole transaction")
    @MainActor
    func conflictRollbackIsAtomic() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 20)
        receiver.context.insert(
            Patient(
                id: ids.patientID,
                displayName: "同 UUID 的不同虚构成员"
            )
        )
        try receiver.context.save()
        let harness = try makeNearbySyncHarness(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        defer { harness.package.cleanup() }

        do {
            _ = try await runNearbySyncHarness(harness)
            Issue.record("conflicting transfer unexpectedly completed")
        } catch {
            #expect(try receiver.context.fetchCount(FetchDescriptor<Patient>()) == 1)
            #expect(
                try receiver.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0
            )
            #expect(
                try receiver.context.fetchCount(FetchDescriptor<Attachment>()) == 0
            )
            #expect(
                try receiver.context.fetchCount(FetchDescriptor<Medication>()) == 0
            )
        }
    }

    @Test("full in-memory single-member transfer uses two real containers")
    @MainActor
    func fullSingleE2E() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 11)
        let result = try await runNearbySyncE2E(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        #expect(result.resultSHA256.count == 64)
        #expect(try receiver.context.fetchCount(FetchDescriptor<Patient>()) == 1)
        #expect(try receiver.context.fetchCount(FetchDescriptor<MedicalRecord>()) == 1)
        #expect(try receiver.context.fetchCount(FetchDescriptor<Attachment>()) == 1)
    }

    @Test("single-member transfer keeps switched audit without captured profile")
    @MainActor
    func crossMemberAuditSingleE2E() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let captured = try sender.seedFullGraph(index: 21, includeAttachment: false)
        let assigned = try sender.seedFullGraph(index: 22, includeAttachment: false)
        let auditID = UUID()
        sender.context.insert(
            RecordAssignmentAudit(
                id: auditID,
                capturedForPatientId: captured.patientID,
                assignedPatientId: assigned.patientID,
                recordId: assigned.recordID,
                detectedName: "测试名22",
                outcome: .mismatch,
                decision: .switchedMember,
                engineIdentifier: "test.offline"
            )
        )
        try sender.context.save()

        _ = try await runNearbySyncE2E(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(assigned.patientID)
        )

        #expect(
            try receiver.context.fetch(FetchDescriptor<Patient>()).map(\.id)
                == [assigned.patientID]
        )
        let transferred = try #require(
            receiver.context.fetch(FetchDescriptor<RecordAssignmentAudit>())
                .first { $0.id == auditID }
        )
        #expect(transferred.capturedForPatientId == captured.patientID)
        #expect(transferred.assignedPatientId == assigned.patientID)
        #expect(transferred.recordId == assigned.recordID)
    }

    @Test("full in-memory all-member transfer preserves both graphs")
    @MainActor
    func fullAllE2E() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let captured = try sender.seedFullGraph(index: 12)
        let assigned = try sender.seedFullGraph(index: 13)
        let auditID = UUID()
        sender.context.insert(
            RecordAssignmentAudit(
                id: auditID,
                capturedForPatientId: captured.patientID,
                assignedPatientId: assigned.patientID,
                recordId: assigned.recordID,
                detectedName: "测试名13",
                outcome: .mismatch,
                decision: .switchedMember,
                engineIdentifier: "test.offline"
            )
        )
        try sender.context.save()
        _ = try await runNearbySyncE2E(
            sender: sender,
            receiver: receiver,
            scope: .allPatients
        )
        #expect(try receiver.context.fetchCount(FetchDescriptor<Patient>()) == 2)
        #expect(try receiver.context.fetchCount(FetchDescriptor<ContentRevision>()) == 2)
        #expect(try receiver.context.fetchCount(FetchDescriptor<ReminderSchedule>()) == 2)
        #expect(
            try receiver.context.fetch(FetchDescriptor<RecordAssignmentAudit>())
                .contains { $0.id == auditID }
        )
    }

    @Test("replaying an identical transfer is idempotent")
    @MainActor
    func fullReplayIsIdempotent() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 14)
        _ = try await runNearbySyncE2E(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        _ = try await runNearbySyncE2E(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        #expect(try receiver.context.fetchCount(FetchDescriptor<Patient>()) == 1)
        #expect(try receiver.context.fetchCount(FetchDescriptor<Attachment>()) == 1)
    }

    @Test("full transfer preserves immutable original bytes")
    @MainActor
    func fullTransferPreservesOriginal() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 15)
        _ = try await runNearbySyncE2E(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        let attachment = try #require(
            try receiver.context.fetch(FetchDescriptor<Attachment>()).first
        )
        let url = try receiver.vault.url(for: attachment.originalRelativePath)
        #expect(try TransferFileHashing.sha256(url: url) == attachment.sha256)
    }

    @Test("full transfer restores non-file entity families")
    @MainActor
    func fullTransferRestoresEntityFamilies() async throws {
        let sender = try NearbySyncTestEnvironment.make()
        let receiver = try NearbySyncTestEnvironment.make()
        let ids = try sender.seedFullGraph(index: 16)
        _ = try await runNearbySyncE2E(
            sender: sender,
            receiver: receiver,
            scope: .singlePatient(ids.patientID)
        )
        #expect(try receiver.context.fetchCount(FetchDescriptor<Medication>()) == 1)
        #expect(try receiver.context.fetchCount(FetchDescriptor<MedicalOrder>()) == 1)
        #expect(try receiver.context.fetchCount(FetchDescriptor<FollowUp>()) == 1)
        #expect(try receiver.context.fetchCount(FetchDescriptor<LabMeasurement>()) == 1)
        #expect(try receiver.context.fetchCount(FetchDescriptor<RecordTag>()) == 1)
        #expect(
            try receiver.context.fetchCount(FetchDescriptor<RecordAssignmentAudit>()) == 1
        )
    }

    @Test("view model exposes deterministic pairing state")
    @MainActor
    func viewModelPairingState() async {
        let model = makeViewModel()
        model.consume(.pairingCode(alias: "ct-1234567890ab", code: "123456"))
        #expect(
            model.phase
                == .pairing(alias: "ct-1234567890ab", code: "123456")
        )
    }

    @Test("view model exposes deterministic progress state")
    @MainActor
    func viewModelProgressState() throws {
        let model = makeViewModel()
        let progress = try TransferProgress(completedBytes: 5, totalBytes: 10)
        model.consume(.progress(progress))
        #expect(model.phase == .transferring(progress))
    }

    @Test("迁移完成只记录一次最近迁移时间")
    @MainActor
    func viewModelRecordsCompletionOnce() {
        var completionCount = 0
        let model = NearbySyncViewModel(
            members: [],
            startSend: { _ in },
            startReceive: {},
            pairingDecision: { _ in },
            manifestDecision: { _ in },
            cancel: {},
            resume: {},
            recordCompletion: { completionCount += 1 }
        )

        model.complete("fictional-result")
        model.complete("fictional-result")

        #expect(completionCount == 1)
        #expect(model.phase == .completed("fictional-result"))
    }

    @MainActor
    private func makeViewModel() -> NearbySyncViewModel {
        NearbySyncViewModel(
            members: [],
            startSend: { _ in },
            startReceive: {},
            pairingDecision: { _ in },
            manifestDecision: { _ in },
            cancel: {},
            resume: {}
        )
    }

    private func expectRelationshipPayloadRejected(
        _ payload: NearbySyncEntityPayloadV1,
        against snapshot: NearbySyncEntitySnapshot
    ) throws {
        let envelope = try TransferDomainEnvelopeV1.decodeStrict(
            from: try snapshot.envelopeData()
        )
        #expect(throws: NearbySyncError.payloadMismatch) {
            _ = try NearbySyncEntityPayloadV1.decode(
                try payload.encoded(),
                envelope: envelope
            )
        }
    }
}
