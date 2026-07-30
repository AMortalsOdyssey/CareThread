import CryptoKit
import Foundation

enum NearbySyncContract {
    static let capability = TransferCapability(
        identifier: "carethread.full-domain",
        version: 1
    )
    static let maximumApplicationPayloadBytes = 180 * 1_024
    static let maximumTransferBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
}

enum NearbySyncError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedEntity(String)
    case malformedPayload
    case payloadMismatch
    case relationshipClosure(UUID)
    case missingOriginal(UUID)
    case originalChanged(UUID)
    case memberLimit
    case conflict(UUID)
    case cancelled
    case storageUnavailable
    case incompleteTransfer

    var errorDescription: String? {
        switch self {
        case let .unsupportedEntity(reason):
            return "当前资料暂不能无损迁移：\(reason)"
        case .malformedPayload:
            return "迁移资料格式无效。"
        case .payloadMismatch:
            return "迁移资料与清单不一致。"
        case .relationshipClosure:
            return "迁移资料存在范围外关联，已停止导出。"
        case .missingOriginal:
            return "病历原文件缺失，已停止导出。"
        case .originalChanged:
            return "病历原文件与入库摘要不一致，已停止导出。"
        case .memberLimit:
            return "导入后将超过 20 位成员。"
        case .conflict:
            return "本机存在同标识但内容不同的资料，未写入任何数据。"
        case .cancelled:
            return "迁移已取消。"
        case .storageUnavailable:
            return "可用空间不足，无法安全接收。"
        case .incompleteTransfer:
            return "迁移内容不完整，未写入任何数据。"
        }
    }
}

/// The app-owned, lossless V1 body carried inside the audited transfer
/// envelope. Exactly one body must match `kind`; unknown fields fail Codable
/// decoding and the transfer layer separately bounds the containing payload.
struct NearbySyncEntityPayloadV1: Codable {
    let schemaVersion: Int
    let kind: TransferEntityKind
    let entityID: UUID
    let patientID: UUID
    let patient: PatientBody?
    let medicalRecord: MedicalRecordBody?
    let attachment: AttachmentBody?
    let medication: MedicationBody?
    let medicalOrder: MedicalOrderBody?
    let followUp: FollowUpBody?
    let labMeasurement: LabMeasurementBody?
    let reminder: ReminderBody?
    let assignmentAudit: AssignmentAuditBody?
    let recordTag: RecordTagBody?
    let contentRevision: ContentRevisionBody?

    struct PatientBody: Codable {
        let editable: PatientEditableContent
        let createdAt: Date
        let contentRevision: Int
    }

    struct MedicalRecordBody: Codable {
        let editable: MedicalRecordEditableContent
        let sourceType: SourceType
        let ocrText: String?
        let ocrEngineIdentifier: String?
        let ocrEngineVersion: String?
        let extractionSchemaVersion: Int
        let machineExtractionRevision: Int
        let machineExtraction: ExtractionResult?
        let createdAt: Date
        let contentRevision: Int
    }

    struct AttachmentBody: Codable {
        let recordID: UUID
        let displayFileName: String
        let uniformTypeIdentifier: String
        let byteCount: Int64
        let sha256: String
        let importedAt: Date
        let importSource: ImportSource
        let pixelWidth: Int?
        let pixelHeight: Int?
        let pageCount: Int?
        let kind: AttachmentKind
        let pageIndex: Int
    }

    struct MedicationBody: Codable {
        let editable: MedicationEditableContent
        let sourceRecordID: UUID?
        let previousVersionID: UUID?
        let createdAt: Date
        let contentRevision: Int
    }

    struct MedicalOrderBody: Codable {
        let editable: MedicalOrderEditableContent
        let sourceRecordID: UUID?
        let generatedFollowUpID: UUID?
        let createdAt: Date
        let contentRevision: Int
    }

    struct FollowUpBody: Codable {
        let editable: FollowUpEditableContent
        let sourceOrderID: UUID?
        let createdAt: Date
        let contentRevision: Int
    }

    struct LabMeasurementBody: Codable {
        let editable: LabMeasurementEditableContent
        let recordID: UUID
        let contentRevision: Int
    }

    struct ReminderBody: Codable {
        let editable: ReminderEditableContent
        let sourceRecordID: UUID?
        let sourceMedicationID: UUID?
        let sourceFollowUpID: UUID?
        let createdAt: Date
        let contentRevision: Int
    }

    struct AssignmentAuditBody: Codable {
        let capturedForPatientID: UUID
        let assignedPatientID: UUID?
        let draftID: UUID?
        let recordID: UUID?
        let detectedName: String?
        let outcome: RecordAssignmentOutcome
        let decision: AssignmentDecision
        let overrideReason: String?
        let engineIdentifier: String
        let engineVersion: String?
        let createdAt: Date
    }

    struct RecordTagBody: Codable {
        let editable: RecordTagEditableContent
        let recordID: UUID
        let contentRevision: Int
    }

    struct ContentRevisionBody: Codable {
        let entityKind: EditableEntityKind
        let targetEntityID: UUID
        let revision: Int
        let changedFieldKeys: [String]
        let beforeContentPayload: Data
        let afterContentPayload: Data
        let source: ContentRevisionSource
        let actor: ContentRevisionActor
        let createdAt: Date
    }

    init(
        kind: TransferEntityKind,
        entityID: UUID,
        patientID: UUID,
        patient: PatientBody? = nil,
        medicalRecord: MedicalRecordBody? = nil,
        attachment: AttachmentBody? = nil,
        medication: MedicationBody? = nil,
        medicalOrder: MedicalOrderBody? = nil,
        followUp: FollowUpBody? = nil,
        labMeasurement: LabMeasurementBody? = nil,
        reminder: ReminderBody? = nil,
        assignmentAudit: AssignmentAuditBody? = nil,
        recordTag: RecordTagBody? = nil,
        contentRevision: ContentRevisionBody? = nil
    ) {
        schemaVersion = 1
        self.kind = kind
        self.entityID = entityID
        self.patientID = patientID
        self.patient = patient
        self.medicalRecord = medicalRecord
        self.attachment = attachment
        self.medication = medication
        self.medicalOrder = medicalOrder
        self.followUp = followUp
        self.labMeasurement = labMeasurement
        self.reminder = reminder
        self.assignmentAudit = assignmentAudit
        self.recordTag = recordTag
        self.contentRevision = contentRevision
    }

    func validate(
        kind expectedKind: TransferEntityKind,
        entityID expectedEntityID: UUID,
        patientID expectedPatientID: UUID
    ) throws {
        guard schemaVersion == 1,
              kind == expectedKind,
              entityID == expectedEntityID,
              patientID == expectedPatientID else {
            throw NearbySyncError.payloadMismatch
        }
        let bodies: [Any?] = [
            patient, medicalRecord, attachment, medication, medicalOrder,
            followUp, labMeasurement, reminder, assignmentAudit, recordTag,
            contentRevision
        ]
        guard bodies.compactMap({ $0 }).count == 1 else {
            throw NearbySyncError.malformedPayload
        }
        let matches: Bool
        switch kind {
        case .patient: matches = patient != nil
        case .medicalRecord: matches = medicalRecord != nil
        case .attachment: matches = attachment != nil
        case .medication: matches = medication != nil
        case .medicalOrder: matches = medicalOrder != nil
        case .followUp: matches = followUp != nil
        case .labMeasurement: matches = labMeasurement != nil
        case .reminder: matches = reminder != nil
        case .assignmentAudit: matches = assignmentAudit != nil
        case .recordTag: matches = recordTag != nil
        case .contentRevision: matches = contentRevision != nil
        }
        guard matches else { throw NearbySyncError.payloadMismatch }
    }

    func encoded() throws -> Data {
        let data = try StableJSON.encode(self)
        guard !data.isEmpty,
              data.count <= NearbySyncContract.maximumApplicationPayloadBytes else {
            throw NearbySyncError.unsupportedEntity("单条资料超过可迁移大小上限")
        }
        return data
    }

    static func decode(
        _ data: Data,
        envelope: ValidatedTransferDomainEnvelopeV1
    ) throws -> NearbySyncEntityPayloadV1 {
        guard !data.isEmpty,
              data.count <= NearbySyncContract.maximumApplicationPayloadBytes else {
            throw NearbySyncError.malformedPayload
        }
        let value: NearbySyncEntityPayloadV1
        do {
            value = try StableJSON.decode(Self.self, from: data)
        } catch {
            throw NearbySyncError.malformedPayload
        }
        try value.validate(
            kind: envelope.kind,
            entityID: envelope.entityID,
            patientID: envelope.patientID
        )
        try NearbySyncEntityRelationshipPolicy.validateEnvelope(
            payload: value,
            envelope: envelope
        )
        return value
    }
}

struct NearbySyncRelationshipTarget: Sendable {
    let kind: TransferEntityKind
    let patientID: UUID
}

/// The single V1 source of truth for every portable body's foreign-key
/// contract. Both Nearby transfer and backup restore use this policy so a body
/// cannot smuggle a relationship that is absent from, or disagrees with, its
/// audited envelope.
enum NearbySyncEntityRelationshipPolicy {
    static func canonicalReferences(
        for payload: NearbySyncEntityPayloadV1
    ) throws -> [TransferEntityReference] {
        var values: [TransferEntityReference] = []
        func append(_ id: UUID?, _ kind: TransferEntityKind) {
            guard let id else { return }
            values.append(.init(entityID: id, kind: kind))
        }

        switch payload.kind {
        case .patient, .medicalRecord:
            break
        case .attachment:
            guard let body = payload.attachment else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.recordID, .medicalRecord)
        case .medication:
            guard let body = payload.medication else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.sourceRecordID, .medicalRecord)
            append(body.previousVersionID, .medication)
        case .medicalOrder:
            guard let body = payload.medicalOrder else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.sourceRecordID, .medicalRecord)
            append(body.generatedFollowUpID, .followUp)
        case .followUp:
            guard let body = payload.followUp else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.sourceOrderID, .medicalOrder)
            body.editable.bringRecordIds.forEach {
                append($0, .medicalRecord)
            }
            append(body.editable.compareRecordId, .medicalRecord)
            append(body.editable.resultRecordId, .medicalRecord)
        case .labMeasurement:
            guard let body = payload.labMeasurement else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.recordID, .medicalRecord)
        case .reminder:
            guard let body = payload.reminder else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.sourceRecordID, .medicalRecord)
            append(body.sourceMedicationID, .medication)
            append(body.sourceFollowUpID, .followUp)
        case .assignmentAudit:
            guard let body = payload.assignmentAudit else {
                throw NearbySyncError.payloadMismatch
            }
            let recordID = try RecordAssignmentTransferPolicy.validateStructure(
                capturedForPatientID: body.capturedForPatientID,
                assignedPatientID: body.assignedPatientID,
                recordID: body.recordID,
                outcome: body.outcome,
                decision: body.decision,
                overrideReason: body.overrideReason,
                expectedOwnerPatientID: payload.patientID
            )
            append(recordID, .medicalRecord)
        case .recordTag:
            guard let body = payload.recordTag else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.recordID, .medicalRecord)
        case .contentRevision:
            guard let body = payload.contentRevision,
                  let targetKind = NearbySyncSnapshotFactory.transferKind(
                      for: body.entityKind
                  ) else {
                throw NearbySyncError.payloadMismatch
            }
            append(body.targetEntityID, targetKind)
        }

        var seen: Set<UUID> = []
        return values
            .filter { seen.insert($0.entityID).inserted }
            .sorted { $0.entityID.uuidString < $1.entityID.uuidString }
    }

    static func validateEnvelope(
        payload: NearbySyncEntityPayloadV1,
        envelope: ValidatedTransferDomainEnvelopeV1
    ) throws {
        let references: [TransferEntityReference]
        do {
            references = try canonicalReferences(for: payload)
        } catch {
            throw NearbySyncError.payloadMismatch
        }
        guard envelope.references == references else {
            throw NearbySyncError.payloadMismatch
        }

        let matchesTypedForeignKeys: Bool
        switch (payload.kind, envelope.fields) {
        case let (.attachment, .attachment(recordID, originalFileID, mediaType, sha256)):
            matchesTypedForeignKeys =
                payload.attachment?.recordID == recordID
                && payload.entityID == originalFileID
                && payload.attachment?.uniformTypeIdentifier == mediaType
                && payload.attachment?.sha256 == sha256
        case (.medication, .medication):
            matchesTypedForeignKeys = true
        case (.medicalOrder, .medicalOrder):
            matchesTypedForeignKeys = true
        case let (.followUp, .followUp(_, _, medicalOrderID)):
            matchesTypedForeignKeys =
                payload.followUp?.sourceOrderID == medicalOrderID
        case let (.labMeasurement, .labMeasurement(_, _, recordID)):
            matchesTypedForeignKeys =
                payload.labMeasurement?.recordID == recordID
        case let (.reminder, .reminder(_, _, _, medicationID, recordID)):
            matchesTypedForeignKeys =
                payload.reminder?.sourceMedicationID == medicationID
                && payload.reminder?.sourceRecordID == recordID
        case let (.assignmentAudit, .assignmentAudit(action, _, recordID)):
            matchesTypedForeignKeys =
                payload.assignmentAudit?.decision.rawValue == action
                && payload.assignmentAudit?.recordID == recordID
        case let (.recordTag, .recordTag(recordID, _)):
            matchesTypedForeignKeys = payload.recordTag?.recordID == recordID
        case let (
            .contentRevision,
            .contentRevision(targetID, targetKind, revision, payloadSHA256)
        ):
            guard let body = payload.contentRevision else {
                throw NearbySyncError.payloadMismatch
            }
            matchesTypedForeignKeys =
                body.targetEntityID == targetID
                && NearbySyncSnapshotFactory.transferKind(
                    for: body.entityKind
                ) == targetKind
                && body.revision == revision
                && Data(SHA256.hash(data: body.afterContentPayload)).hexString
                    == payloadSHA256
        case (.patient, .patient), (.medicalRecord, .medicalRecord):
            matchesTypedForeignKeys = true
        default:
            matchesTypedForeignKeys = false
        }
        guard matchesTypedForeignKeys else {
            throw NearbySyncError.payloadMismatch
        }
    }

    static func validateTargetClosure(
        payload: NearbySyncEntityPayloadV1,
        targetsByID: [UUID: NearbySyncRelationshipTarget]
    ) throws {
        let references = try canonicalReferences(for: payload)
        for reference in references {
            guard let target = targetsByID[reference.entityID],
                  target.kind == reference.kind,
                  target.patientID == payload.patientID else {
                throw NearbySyncError.relationshipClosure(payload.entityID)
            }
        }
    }
}

struct NearbySyncEntitySnapshot {
    let kind: TransferEntityKind
    let entityID: UUID
    let patientID: UUID
    let revision: Int
    let references: [TransferEntityReference]
    let fields: [String: String]
    let payload: NearbySyncEntityPayloadV1
    let originalRelativePath: String?

    func envelopeData() throws -> Data {
        var completeFields = fields
        completeFields["portablePayloadBase64"] = try payload.encoded().base64EncodedString()
        return try StableJSON.encode(
            TransferDomainEnvelopeV1(
                kind: kind,
                entityID: entityID,
                patientID: patientID,
                revision: revision,
                references: references,
                fields: completeFields
            )
        )
    }

    func fingerprint() throws -> String {
        Data(SHA256.hash(data: try envelopeData())).hexString
    }
}

enum NearbySyncSnapshotFactory {
    static func make(_ patient: Patient) -> NearbySyncEntitySnapshot {
        snapshot(
            kind: .patient,
            id: patient.id,
            patientID: patient.id,
            revision: patient.contentRevision,
            fields: ["displayName": patient.displayName],
            payload: NearbySyncEntityPayloadV1(
                kind: .patient,
                entityID: patient.id,
                patientID: patient.id,
                patient: .init(
                    editable: patient.editableContent(),
                    createdAt: patient.createdAt,
                    contentRevision: patient.contentRevision
                )
            )
        )
    }

    static func make(_ record: MedicalRecord) -> NearbySyncEntitySnapshot {
        snapshot(
            kind: .medicalRecord,
            id: record.id,
            patientID: record.patientId,
            revision: record.contentRevision,
            fields: [
                "recordType": record.type.rawValue,
                "eventDateUTC": iso(record.eventDate),
                "title": record.title
            ],
            payload: NearbySyncEntityPayloadV1(
                kind: .medicalRecord,
                entityID: record.id,
                patientID: record.patientId,
                medicalRecord: .init(
                    editable: record.editableContent(),
                    sourceType: record.sourceType,
                    ocrText: record.ocrText,
                    ocrEngineIdentifier: record.ocrEngineIdentifier,
                    ocrEngineVersion: record.ocrEngineVersion,
                    extractionSchemaVersion: record.extractionSchemaVersion,
                    machineExtractionRevision: record.machineExtractionRevision,
                    machineExtraction: record.machineExtraction,
                    createdAt: record.createdAt,
                    contentRevision: record.contentRevision
                )
            )
        )
    }

    static func make(_ attachment: Attachment) throws -> NearbySyncEntitySnapshot {
        guard let recordID = attachment.recordId else {
            throw NearbySyncError.unsupportedEntity("存在尚未归入病历的附件")
        }
        return snapshot(
            kind: .attachment,
            id: attachment.id,
            patientID: attachment.patientId,
            revision: 0,
            references: [.init(entityID: recordID, kind: .medicalRecord)],
            fields: [
                "recordID": recordID.uuidString,
                "originalFileID": attachment.id.uuidString,
                "mediaType": attachment.uniformTypeIdentifier,
                "sha256": attachment.sha256
            ],
            payload: NearbySyncEntityPayloadV1(
                kind: .attachment,
                entityID: attachment.id,
                patientID: attachment.patientId,
                attachment: .init(
                    recordID: recordID,
                    displayFileName: attachment.displayFileName,
                    uniformTypeIdentifier: attachment.uniformTypeIdentifier,
                    byteCount: attachment.byteCount,
                    sha256: attachment.sha256,
                    importedAt: attachment.importedAt,
                    importSource: attachment.importSource,
                    pixelWidth: attachment.pixelWidth,
                    pixelHeight: attachment.pixelHeight,
                    pageCount: attachment.pageCount,
                    kind: attachment.kind,
                    pageIndex: attachment.pageIndex
                )
            ),
            originalRelativePath: attachment.originalRelativePath
        )
    }

    static func make(_ medication: Medication) -> NearbySyncEntitySnapshot {
        var references: [TransferEntityReference] = []
        append(medication.sourceRecordId, .medicalRecord, to: &references)
        append(medication.previousVersionId, .medication, to: &references)
        return snapshot(
            kind: .medication,
            id: medication.id,
            patientID: medication.patientId,
            revision: medication.contentRevision,
            references: references,
            fields: ["name": medication.name],
            payload: NearbySyncEntityPayloadV1(
                kind: .medication,
                entityID: medication.id,
                patientID: medication.patientId,
                medication: .init(
                    editable: medication.editableContent(),
                    sourceRecordID: medication.sourceRecordId,
                    previousVersionID: medication.previousVersionId,
                    createdAt: medication.createdAt,
                    contentRevision: medication.contentRevision
                )
            )
        )
    }

    static func make(_ order: MedicalOrder) -> NearbySyncEntitySnapshot {
        var references: [TransferEntityReference] = []
        append(order.sourceRecordId, .medicalRecord, to: &references)
        append(order.generatedFollowUpId, .followUp, to: &references)
        return snapshot(
            kind: .medicalOrder,
            id: order.id,
            patientID: order.patientId,
            revision: order.contentRevision,
            references: references,
            fields: [
                "title": order.content,
                "orderedAtUTC": iso(order.createdAt)
            ],
            payload: NearbySyncEntityPayloadV1(
                kind: .medicalOrder,
                entityID: order.id,
                patientID: order.patientId,
                medicalOrder: .init(
                    editable: order.editableContent(),
                    sourceRecordID: order.sourceRecordId,
                    generatedFollowUpID: order.generatedFollowUpId,
                    createdAt: order.createdAt,
                    contentRevision: order.contentRevision
                )
            )
        )
    }

    static func make(_ followUp: FollowUp) -> NearbySyncEntitySnapshot {
        var references: [TransferEntityReference] = []
        append(followUp.sourceOrderId, .medicalOrder, to: &references)
        followUp.bringRecordIds.forEach { append($0, .medicalRecord, to: &references) }
        append(followUp.compareRecordId, .medicalRecord, to: &references)
        append(followUp.resultRecordId, .medicalRecord, to: &references)
        return snapshot(
            kind: .followUp,
            id: followUp.id,
            patientID: followUp.patientId,
            revision: followUp.contentRevision,
            references: unique(references),
            fields: [
                "title": followUp.items.first ?? "复查",
                "dueAtUTC": iso(followUp.plannedDate)
            ].merging(
                followUp.sourceOrderId.map { ["medicalOrderID": $0.uuidString] } ?? [:]
            ) { _, new in new },
            payload: NearbySyncEntityPayloadV1(
                kind: .followUp,
                entityID: followUp.id,
                patientID: followUp.patientId,
                followUp: .init(
                    editable: followUp.editableContent(),
                    sourceOrderID: followUp.sourceOrderId,
                    createdAt: followUp.createdAt,
                    contentRevision: followUp.contentRevision
                )
            )
        )
    }

    static func make(_ measurement: LabMeasurement) -> NearbySyncEntitySnapshot {
        snapshot(
            kind: .labMeasurement,
            id: measurement.id,
            patientID: measurement.patientId,
            revision: measurement.contentRevision,
            references: [.init(entityID: measurement.recordId, kind: .medicalRecord)],
            fields: [
                "name": measurement.displayName,
                "observedAtUTC": iso(measurement.eventDate),
                "recordID": measurement.recordId.uuidString
            ],
            payload: NearbySyncEntityPayloadV1(
                kind: .labMeasurement,
                entityID: measurement.id,
                patientID: measurement.patientId,
                labMeasurement: .init(
                    editable: measurement.editableContent(),
                    recordID: measurement.recordId,
                    contentRevision: measurement.contentRevision
                )
            )
        )
    }

    static func make(_ reminder: ReminderSchedule) -> NearbySyncEntitySnapshot {
        var references: [TransferEntityReference] = []
        append(reminder.sourceRecordId, .medicalRecord, to: &references)
        append(reminder.sourceMedicationId, .medication, to: &references)
        append(reminder.sourceFollowUpId, .followUp, to: &references)
        var fields = [
            "title": reminder.title,
            "dueAtUTC": iso(reminder.schedule.startAt),
            "kind": reminder.kind.rawValue
        ]
        if let id = reminder.sourceMedicationId { fields["medicationID"] = id.uuidString }
        if let id = reminder.sourceRecordId { fields["recordID"] = id.uuidString }
        return snapshot(
            kind: .reminder,
            id: reminder.id,
            patientID: reminder.patientId,
            revision: reminder.contentRevision,
            references: references,
            fields: fields,
            payload: NearbySyncEntityPayloadV1(
                kind: .reminder,
                entityID: reminder.id,
                patientID: reminder.patientId,
                reminder: .init(
                    editable: reminder.editableContent(),
                    sourceRecordID: reminder.sourceRecordId,
                    sourceMedicationID: reminder.sourceMedicationId,
                    sourceFollowUpID: reminder.sourceFollowUpId,
                    createdAt: reminder.createdAt,
                    contentRevision: reminder.contentRevision
                )
            )
        )
    }

    static func make(_ audit: RecordAssignmentAudit) throws -> NearbySyncEntitySnapshot {
        let owner = RecordAssignmentTransferPolicy.ownerPatientID(
            capturedForPatientID: audit.capturedForPatientId,
            assignedPatientID: audit.assignedPatientId
        )
        let recordID: UUID
        do {
            recordID = try RecordAssignmentTransferPolicy.validateStructure(
                capturedForPatientID: audit.capturedForPatientId,
                assignedPatientID: audit.assignedPatientId,
                recordID: audit.recordId,
                outcome: audit.outcome,
                decision: audit.decision,
                overrideReason: audit.overrideReason,
                expectedOwnerPatientID: owner
            )
        } catch {
            throw NearbySyncError.unsupportedEntity("归属审计结构无效")
        }
        return snapshot(
            kind: .assignmentAudit,
            id: audit.id,
            patientID: owner,
            revision: 0,
            references: [
                .init(entityID: recordID, kind: .medicalRecord)
            ],
            fields: [
                "action": audit.decision.rawValue,
                "createdAtUTC": iso(audit.createdAt),
                "recordID": recordID.uuidString
            ],
            payload: NearbySyncEntityPayloadV1(
                kind: .assignmentAudit,
                entityID: audit.id,
                patientID: owner,
                assignmentAudit: .init(
                    capturedForPatientID: audit.capturedForPatientId,
                    assignedPatientID: audit.assignedPatientId,
                    draftID: audit.draftId,
                    recordID: recordID,
                    detectedName: audit.detectedName,
                    outcome: audit.outcome,
                    decision: audit.decision,
                    overrideReason: audit.overrideReason,
                    engineIdentifier: audit.engineIdentifier,
                    engineVersion: audit.engineVersion,
                    createdAt: audit.createdAt
                )
            )
        )
    }

    static func make(_ tag: RecordTag) -> NearbySyncEntitySnapshot {
        snapshot(
            kind: .recordTag,
            id: tag.id,
            patientID: tag.patientId,
            revision: tag.contentRevision,
            references: [.init(entityID: tag.recordId, kind: .medicalRecord)],
            fields: [
                "recordID": tag.recordId.uuidString,
                "name": tag.displayValue
            ],
            payload: NearbySyncEntityPayloadV1(
                kind: .recordTag,
                entityID: tag.id,
                patientID: tag.patientId,
                recordTag: .init(
                    editable: tag.editableContent(),
                    recordID: tag.recordId,
                    contentRevision: tag.contentRevision
                )
            )
        )
    }

    static func make(_ revision: ContentRevision) throws -> NearbySyncEntitySnapshot {
        guard let targetKind = transferKind(for: revision.entityKind) else {
            throw NearbySyncError.unsupportedEntity(
                "存在仅属于导入草稿的修订历史"
            )
        }
        return snapshot(
            kind: .contentRevision,
            id: revision.id,
            patientID: revision.patientId,
            revision: revision.revision,
            references: [.init(entityID: revision.entityId, kind: targetKind)],
            fields: [
                "targetEntityID": revision.entityId.uuidString,
                "targetKind": targetKind.rawValue,
                "revision": String(revision.revision),
                "payloadSHA256": Data(
                    SHA256.hash(data: revision.afterContentPayload)
                ).hexString
            ],
            payload: NearbySyncEntityPayloadV1(
                kind: .contentRevision,
                entityID: revision.id,
                patientID: revision.patientId,
                contentRevision: .init(
                    entityKind: revision.entityKind,
                    targetEntityID: revision.entityId,
                    revision: revision.revision,
                    changedFieldKeys: revision.changedFieldKeys,
                    beforeContentPayload: revision.beforeContentPayload,
                    afterContentPayload: revision.afterContentPayload,
                    source: revision.source,
                    actor: revision.actor,
                    createdAt: revision.createdAt
                )
            )
        )
    }

    private static func snapshot(
        kind: TransferEntityKind,
        id: UUID,
        patientID: UUID,
        revision: Int,
        references: [TransferEntityReference] = [],
        fields: [String: String],
        payload: NearbySyncEntityPayloadV1,
        originalRelativePath: String? = nil
    ) -> NearbySyncEntitySnapshot {
        NearbySyncEntitySnapshot(
            kind: kind,
            entityID: id,
            patientID: patientID,
            revision: max(0, revision),
            references: unique(references),
            fields: fields,
            payload: payload,
            originalRelativePath: originalRelativePath
        )
    }

    private static func append(
        _ id: UUID?,
        _ kind: TransferEntityKind,
        to values: inout [TransferEntityReference]
    ) {
        guard let id else { return }
        values.append(.init(entityID: id, kind: kind))
    }

    private static func unique(
        _ values: [TransferEntityReference]
    ) -> [TransferEntityReference] {
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0.entityID).inserted }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func transferKind(
        for kind: EditableEntityKind
    ) -> TransferEntityKind? {
        switch kind {
        case .patientProfile: .patient
        case .medicalRecord: .medicalRecord
        case .medication: .medication
        case .medicalOrder: .medicalOrder
        case .followUp: .followUp
        case .labMeasurement: .labMeasurement
        case .recordTag: .recordTag
        case .reminder: .reminder
        case .captureDraft, .capturePage: nil
        }
    }
}
