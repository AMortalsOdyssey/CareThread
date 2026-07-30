import Foundation

enum TransferLimits {
    static let protocolVersion = 1
    static let domainSchemaVersion = 1
    static let chunkSize = 64 * 1_024
    static let maximumMembers = 20
    static let maximumEntities = 100_000
    static let maximumFiles = 10_000
    static let maximumChunksPerFile = 32_768
    static let maximumFileBytes = Int64(chunkSize) * Int64(maximumChunksPerFile)
    static let maximumTransferBytes: Int64 = 20 * 1_024 * 1_024 * 1_024
    static let maximumManifestBytes = 8 * 1_024 * 1_024
    /// Domain envelopes are intentionally small enough for bounded one-shot
    /// decoding. Original medical files always use the streaming file path.
    static let maximumDomainPayloadBytes = 256 * 1_024
    static let maximumResumeBitmapBytes = (maximumChunksPerFile + 7) / 8
    static let maximumWireFrames = maximumFiles * 2 + maximumEntities + 1_024
    static let maximumControlFrameBytes = 64 * 1_024
    static let maximumReceiptFrameBytes = 16 * 1_024
    static let maximumStagingBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let minimumFreeSpaceBytes: Int64 = 256 * 1_024 * 1_024
    static let checkpointIntervalChunks = 8
}

enum TransferScope: Hashable, Sendable {
    case singlePatient(UUID)
    case allPatients

    var patientID: UUID? {
        if case let .singlePatient(patientID) = self {
            return patientID
        }
        return nil
    }
}

extension TransferScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case patientID
    }

    private enum Kind: String, Codable {
        case singlePatient
        case allPatients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .singlePatient:
            self = .singlePatient(try container.decode(UUID.self, forKey: .patientID))
        case .allPatients:
            guard !container.contains(.patientID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .patientID,
                    in: container,
                    debugDescription: "allPatients must not carry patientID"
                )
            }
            self = .allPatients
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .singlePatient(patientID):
            try container.encode(Kind.singlePatient, forKey: .kind)
            try container.encode(patientID, forKey: .patientID)
        case .allPatients:
            try container.encode(Kind.allPatients, forKey: .kind)
        }
    }
}

enum TransferEntityKind: String, Codable, CaseIterable, Sendable {
    case patient
    case medicalRecord
    case attachment
    case medication
    case medicalOrder
    case followUp
    case labMeasurement
    case reminder
    case assignmentAudit
    case recordTag
    case contentRevision
}

enum TransferFileKind: String, Codable, CaseIterable, Sendable {
    case domainSnapshot
    case originalAttachment
}

struct TransferCapability: Codable, Hashable, Sendable {
    let identifier: String
    let version: Int
}

struct TransferEntityDescriptor: Codable, Hashable, Sendable {
    let kind: TransferEntityKind
    let entityID: UUID
    let patientID: UUID
    let payloadFileID: UUID
    let revision: Int
}

struct TransferFileDescriptor: Codable, Hashable, Sendable {
    let kind: TransferFileKind
    let fileID: UUID
    let patientID: UUID
    /// Required only for an original file. It is the reverse edge back to the
    /// single Attachment entity that owns this immutable source.
    let ownerAttachmentID: UUID?
    /// Sender-side display/export metadata only. The receiver never resolves this path.
    let relativePath: String
    let byteCount: Int64
    let sha256: String
    let chunkSize: Int

    init(
        kind: TransferFileKind,
        fileID: UUID,
        patientID: UUID,
        ownerAttachmentID: UUID? = nil,
        relativePath: String,
        byteCount: Int64,
        sha256: String,
        chunkSize: Int = TransferLimits.chunkSize
    ) {
        self.kind = kind
        self.fileID = fileID
        self.patientID = patientID
        self.ownerAttachmentID = ownerAttachmentID
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
        self.chunkSize = chunkSize
    }

    var totalChunkCount: Int {
        guard byteCount > 0, chunkSize > 0 else { return 0 }
        let quotient = byteCount / Int64(chunkSize)
        let remainder = byteCount % Int64(chunkSize)
        let count = quotient + (remainder == 0 ? 0 : 1)
        return count <= Int64(Int.max) ? Int(count) : Int.max
    }

    func validated() throws -> ValidatedTransferFileDescriptor {
        guard byteCount >= 0, byteCount <= TransferLimits.maximumFileBytes else {
            throw TransferProtocolError.limitExceeded("file byteCount")
        }
        guard chunkSize == TransferLimits.chunkSize else {
            throw TransferProtocolError.invalidManifest("chunk size must be 64KiB")
        }
        guard totalChunkCount <= TransferLimits.maximumChunksPerFile else {
            throw TransferProtocolError.limitExceeded("file chunk count")
        }
        guard sha256.count == 64,
              sha256.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw TransferProtocolError.invalidManifest("invalid sha256")
        }
        guard Self.isSafeMetadataPath(relativePath, patientID: patientID) else {
            throw TransferProtocolError.invalidManifest("unsafe relative path")
        }
        if kind == .domainSnapshot, byteCount > Int64(TransferLimits.maximumDomainPayloadBytes) {
            throw TransferProtocolError.limitExceeded("domain payload")
        }
        switch kind {
        case .domainSnapshot:
            guard ownerAttachmentID == nil else {
                throw TransferProtocolError.invalidManifest(
                    "domain snapshot must not claim attachment"
                )
            }
        case .originalAttachment:
            guard ownerAttachmentID != nil, byteCount > 0 else {
                throw TransferProtocolError.invalidManifest(
                    "original file requires owner attachment"
                )
            }
        }
        return ValidatedTransferFileDescriptor(self)
    }

    private static func isSafeMetadataPath(_ path: String, patientID: UUID) -> Bool {
        guard !path.isEmpty,
              path.count <= 512,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              path == path.precomposedStringWithCanonicalMapping else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3,
              components[0] == "members",
              components[1].lowercased() == patientID.uuidString.lowercased(),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        return true
    }
}

/// Capability returned only after every descriptor bound is checked.
struct ValidatedTransferFileDescriptor: Sendable {
    fileprivate let raw: TransferFileDescriptor

    fileprivate init(_ raw: TransferFileDescriptor) {
        self.raw = raw
    }

    var fileID: UUID { raw.fileID }
    var patientID: UUID { raw.patientID }
    var ownerAttachmentID: UUID? { raw.ownerAttachmentID }
    var kind: TransferFileKind { raw.kind }
    var byteCount: Int64 { raw.byteCount }
    var sha256: String { raw.sha256 }
    var chunkSize: Int { raw.chunkSize }
    var totalChunkCount: Int { raw.totalChunkCount }
}

struct TransferPreviewCounts: Codable, Hashable, Sendable {
    let memberCount: Int
    let recordCount: Int
    let attachmentCount: Int
}

struct TransferManifest: Codable, Hashable, Sendable {
    let protocolVersion: Int
    let minimumReceiverVersion: Int
    let transferID: UUID
    let scope: TransferScope
    let createdAtUTC: String
    let capabilities: [TransferCapability]
    let preview: TransferPreviewCounts
    let entities: [TransferEntityDescriptor]
    let files: [TransferFileDescriptor]
    let totalByteCount: Int64

    init(
        protocolVersion: Int = TransferLimits.protocolVersion,
        minimumReceiverVersion: Int = TransferLimits.protocolVersion,
        transferID: UUID,
        scope: TransferScope,
        createdAtUTC: String,
        capabilities: [TransferCapability],
        preview: TransferPreviewCounts,
        entities: [TransferEntityDescriptor],
        files: [TransferFileDescriptor]
    ) {
        self.protocolVersion = protocolVersion
        self.minimumReceiverVersion = minimumReceiverVersion
        self.transferID = transferID
        self.scope = scope
        self.createdAtUTC = createdAtUTC
        self.capabilities = capabilities.sorted {
            ($0.identifier, $0.version) < ($1.identifier, $1.version)
        }
        self.preview = preview
        self.entities = entities.sorted {
            ($0.kind.rawValue, $0.entityID.uuidString) <
                ($1.kind.rawValue, $1.entityID.uuidString)
        }
        self.files = files.sorted {
            ($0.kind.rawValue, $0.fileID.uuidString) <
                ($1.kind.rawValue, $1.fileID.uuidString)
        }
        self.totalByteCount = files.reduce(into: Int64(0)) { result, file in
            let (sum, overflow) = result.addingReportingOverflow(file.byteCount)
            result = overflow ? Int64.max : sum
        }
    }

    static func decodeAndValidate(
        from data: Data,
        receiverProtocolVersion: Int = TransferLimits.protocolVersion,
        existingPatientIDs: Set<UUID> = []
    ) throws -> TransferManifest {
        guard !data.isEmpty, data.count <= TransferLimits.maximumManifestBytes else {
            throw TransferProtocolError.limitExceeded("manifest bytes")
        }
        let root = try StrictJSONObject.requireKeys(
            in: data,
            allowed: [
                "protocolVersion", "minimumReceiverVersion", "transferID", "scope",
                "createdAtUTC", "capabilities", "preview", "entities", "files",
                "totalByteCount"
            ],
            required: [
                "protocolVersion", "minimumReceiverVersion", "transferID", "scope",
                "createdAtUTC", "capabilities", "preview", "entities", "files",
                "totalByteCount"
            ]
        )
        try StrictJSONObject.requireNestedManifestShape(root)
        let manifest: TransferManifest
        do {
            manifest = try StableJSON.decode(TransferManifest.self, from: data)
        } catch {
            throw TransferProtocolError.invalidManifest("malformed JSON")
        }
        try manifest.validate(
            receiverProtocolVersion: receiverProtocolVersion,
            existingPatientIDs: existingPatientIDs
        )
        return manifest
    }

    func validate(
        receiverProtocolVersion: Int = TransferLimits.protocolVersion,
        existingPatientIDs: Set<UUID> = []
    ) throws {
        guard protocolVersion == TransferLimits.protocolVersion,
              minimumReceiverVersion == TransferLimits.protocolVersion,
              receiverProtocolVersion == TransferLimits.protocolVersion else {
            throw TransferProtocolError.unsupportedVersion(
                offered: protocolVersion,
                minimumReceiver: minimumReceiverVersion,
                local: receiverProtocolVersion
            )
        }
        guard ISO8601DateFormatter().date(from: createdAtUTC) != nil else {
            throw TransferProtocolError.invalidManifest("createdAtUTC")
        }
        guard !entities.isEmpty, entities.count <= TransferLimits.maximumEntities else {
            throw TransferProtocolError.limitExceeded("entities")
        }
        guard !files.isEmpty, files.count <= TransferLimits.maximumFiles else {
            throw TransferProtocolError.limitExceeded("files")
        }

        let capabilityIDs = Set(capabilities.map(\.identifier))
        guard capabilities.count <= 64,
              capabilityIDs.count == capabilities.count,
              capabilities.allSatisfy({
                  !$0.identifier.isEmpty &&
                      $0.identifier.count <= 64 &&
                      $0.identifier.unicodeScalars.allSatisfy(\.isASCII) &&
                      $0.version > 0
              }) else {
            throw TransferProtocolError.invalidManifest("invalid capability")
        }
        guard capabilities.contains(
            TransferCapability(identifier: "domain.json", version: 1)
        ) else {
            throw TransferProtocolError.invalidManifest("missing domain.json v1")
        }

        let patientDescriptors = entities.filter { $0.kind == .patient }
        let patientIDs = Set(patientDescriptors.map(\.patientID))
        guard !patientIDs.isEmpty,
              patientIDs.count <= TransferLimits.maximumMembers,
              patientDescriptors.count == patientIDs.count,
              patientDescriptors.allSatisfy({ $0.entityID == $0.patientID }) else {
            throw TransferProtocolError.invalidManifest("invalid patient descriptors")
        }
        let resultingPatients = existingPatientIDs.union(patientIDs)
        guard resultingPatients.count <= TransferLimits.maximumMembers else {
            throw TransferProtocolError.limitExceeded("existing plus imported members")
        }

        switch scope {
        case let .singlePatient(patientID):
            guard patientIDs == [patientID],
                  entities.allSatisfy({ $0.patientID == patientID }),
                  files.allSatisfy({ $0.patientID == patientID }) else {
                throw TransferProtocolError.scopeViolation
            }
        case .allPatients:
            guard Set(entities.map(\.patientID)) == patientIDs,
                  Set(files.map(\.patientID)) == patientIDs else {
                throw TransferProtocolError.scopeViolation
            }
        }

        let expectedPreview = TransferPreviewCounts(
            memberCount: patientIDs.count,
            recordCount: entities.lazy.filter { $0.kind == .medicalRecord }.count,
            attachmentCount: entities.lazy.filter { $0.kind == .attachment }.count
        )
        guard preview == expectedPreview else {
            throw TransferProtocolError.invalidManifest("preview count mismatch")
        }

        let fileIDs = Set(files.map(\.fileID))
        guard fileIDs.count == files.count else {
            throw TransferProtocolError.invalidManifest("duplicate file id")
        }
        let entityIDs = Set(entities.map(\.entityID))
        guard entityIDs.count == entities.count else {
            throw TransferProtocolError.invalidManifest("duplicate entity id")
        }
        guard Set(entities.map(\.payloadFileID)).count == entities.count else {
            throw TransferProtocolError.invalidManifest("payload file must bind one entity")
        }
        guard Set(files.map(\.relativePath)).count == files.count else {
            throw TransferProtocolError.invalidManifest("duplicate relative path")
        }

        var recomputedTotal: Int64 = 0
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.fileID, $0) })
        for file in files {
            _ = try file.validated()
            let (sum, overflow) = recomputedTotal.addingReportingOverflow(file.byteCount)
            guard !overflow, sum <= TransferLimits.maximumTransferBytes else {
                throw TransferProtocolError.limitExceeded("totalByteCount")
            }
            recomputedTotal = sum
        }
        guard recomputedTotal == totalByteCount else {
            throw TransferProtocolError.invalidManifest("totalByteCount mismatch")
        }
        for entity in entities {
            guard entity.revision >= 0,
                  let payloadFile = filesByID[entity.payloadFileID],
                  payloadFile.kind == .domainSnapshot,
                  payloadFile.patientID == entity.patientID else {
                throw TransferProtocolError.invalidManifest("entity payload mismatch")
            }
        }
        let attachmentIDs = Set(
            entities.lazy.filter { $0.kind == .attachment }.map(\.entityID)
        )
        let attachmentsByID = Dictionary(
            uniqueKeysWithValues: entities.lazy
                .filter { $0.kind == .attachment }
                .map { ($0.entityID, $0) }
        )
        let originalOwners = files.compactMap { file -> UUID? in
            file.kind == .originalAttachment ? file.ownerAttachmentID : nil
        }
        guard Set(originalOwners).count == originalOwners.count,
              Set(originalOwners) == attachmentIDs,
              files.lazy.filter({ $0.kind == .originalAttachment }).allSatisfy({
                  guard let ownerID = $0.ownerAttachmentID,
                        let attachment = attachmentsByID[ownerID] else {
                      return false
                  }
                  return attachment.patientID == $0.patientID
              }) else {
            throw TransferProtocolError.invalidManifest(
                "original files must be uniquely and completely owned"
            )
        }
    }
}

struct TransferEntityReference: Codable, Hashable, Sendable {
    let entityID: UUID
    let kind: TransferEntityKind
}

/// The portable V1 domain envelope. Metadata is deliberately duplicated from the
/// manifest so the receiver can reject a swapped or cross-member payload.
struct TransferDomainEnvelopeV1: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let kind: TransferEntityKind
    let entityID: UUID
    let patientID: UUID
    let revision: Int
    let references: [TransferEntityReference]
    let fields: [String: String]

    init(
        kind: TransferEntityKind,
        entityID: UUID,
        patientID: UUID,
        revision: Int,
        references: [TransferEntityReference] = [],
        fields: [String: String]
    ) {
        schemaVersion = TransferLimits.domainSchemaVersion
        self.kind = kind
        self.entityID = entityID
        self.patientID = patientID
        self.revision = revision
        self.references = references.sorted { $0.entityID.uuidString < $1.entityID.uuidString }
        self.fields = fields
    }

    static func decodeStrict(from data: Data) throws -> ValidatedTransferDomainEnvelopeV1 {
        guard !data.isEmpty, data.count <= TransferLimits.maximumDomainPayloadBytes else {
            throw TransferProtocolError.limitExceeded("domain payload")
        }
        let root = try StrictJSONObject.requireKeys(
            in: data,
            allowed: [
                "schemaVersion", "kind", "entityID", "patientID", "revision",
                "references", "fields"
            ],
            required: [
                "schemaVersion", "kind", "entityID", "patientID", "revision",
                "references", "fields"
            ]
        )
        try StrictJSONObject.requireNestedEnvelopeShape(root)
        let value: Self
        do {
            value = try StableJSON.decode(Self.self, from: data)
        } catch {
            throw TransferProtocolError.invalidManifest("malformed domain payload")
        }
        guard value.schemaVersion == 1,
              value.revision >= 0,
              value.references.count <= 10_000,
              Set(value.references.map(\.entityID)).count == value.references.count,
              value.fields.count <= 1_000,
              value.fields.allSatisfy({
                  !$0.key.isEmpty
                      && $0.key.count <= 128
                      && $0.value.count <= (
                          $0.key == TransferDomainFieldSchemaV1.portablePayloadKey
                              ? 245_760
                              : 100_000
                      )
              }) else {
            throw TransferProtocolError.invalidManifest("invalid domain payload")
        }
        let portablePayload = try TransferDomainFieldSchemaV1.portablePayload(
            from: value.fields
        )
        return ValidatedTransferDomainEnvelopeV1(
            schemaVersion: value.schemaVersion,
            kind: value.kind,
            entityID: value.entityID,
            patientID: value.patientID,
            revision: value.revision,
            references: value.references,
            fields: try TransferDomainFieldSchemaV1.decode(
                kind: value.kind,
                fields: value.fields
            ),
            portablePayload: portablePayload
        )
    }
}

struct ValidatedTransferDomainEnvelopeV1: Hashable, Sendable {
    let schemaVersion: Int
    let kind: TransferEntityKind
    let entityID: UUID
    let patientID: UUID
    let revision: Int
    let references: [TransferEntityReference]
    let fields: TransferTypedDomainFieldsV1
    /// Optional, versioned application payload. The transfer layer validates
    /// its canonical base64 shape and bound, while the owning feature validates
    /// the inner schema before any persistent mutation.
    let portablePayload: Data?
}

enum TransferTypedDomainFieldsV1: Hashable, Sendable {
    case patient(displayName: String)
    case medicalRecord(recordType: String, eventDateUTC: String, title: String)
    case attachment(
        recordID: UUID,
        originalFileID: UUID,
        mediaType: String,
        sha256: String
    )
    case medication(name: String)
    case medicalOrder(title: String, orderedAtUTC: String)
    case followUp(title: String, dueAtUTC: String, medicalOrderID: UUID?)
    case labMeasurement(name: String, observedAtUTC: String, recordID: UUID?)
    case reminder(
        title: String,
        dueAtUTC: String,
        reminderKind: String,
        medicationID: UUID?,
        recordID: UUID?
    )
    case assignmentAudit(action: String, createdAtUTC: String, recordID: UUID?)
    case recordTag(recordID: UUID, name: String)
    case contentRevision(
        targetEntityID: UUID,
        targetKind: TransferEntityKind,
        revision: Int,
        payloadSHA256: String
    )
}

/// A V1 payload cannot silently gain fields. Schema evolution must introduce a
/// new domain version and migration rather than relying on permissive Codable.
private enum TransferDomainFieldSchemaV1 {
    static let portablePayloadKey = "portablePayloadBase64"
    private static let maximumPortablePayloadBytes = 180 * 1_024

    private struct Rule {
        let required: Set<String>
        let allowed: Set<String>
    }

    static func decode(
        kind: TransferEntityKind,
        fields: [String: String]
    ) throws -> TransferTypedDomainFieldsV1 {
        let keys = Set(fields.keys)
        let rule = rule(for: kind)
        guard rule.required.isSubset(of: keys), keys.isSubset(of: rule.allowed) else {
            throw TransferProtocolError.invalidManifest("invalid typed fields")
        }
        for key in rule.required where fields[key]?.isEmpty != false {
            throw TransferProtocolError.invalidManifest("invalid typed fields")
        }
        func required(_ key: String) throws -> String {
            guard let value = fields[key], !value.isEmpty else {
                throw TransferProtocolError.invalidManifest("missing \(key)")
            }
            return value
        }
        func uuid(_ key: String) throws -> UUID {
            guard let value = fields[key], let id = UUID(uuidString: value) else {
                throw TransferProtocolError.invalidManifest("invalid \(key)")
            }
            return id
        }
        func optionalUUID(_ key: String) throws -> UUID? {
            guard let value = fields[key] else { return nil }
            guard let id = UUID(uuidString: value) else {
                throw TransferProtocolError.invalidManifest("invalid \(key)")
            }
            return id
        }
        func timestamp(_ key: String) throws -> String {
            let value = try required(key)
            guard ISO8601DateFormatter().date(from: value) != nil else {
                throw TransferProtocolError.invalidManifest("invalid \(key)")
            }
            return value
        }
        func sha256(_ key: String) throws -> String {
            let value = try required(key).lowercased()
            guard value.count == 64,
                  value.unicodeScalars.allSatisfy({
                      ($0.value >= 48 && $0.value <= 57)
                          || ($0.value >= 97 && $0.value <= 102)
                  }) else {
                throw TransferProtocolError.invalidManifest("invalid \(key)")
            }
            return value
        }

        switch kind {
        case .patient:
            return .patient(displayName: try required("displayName"))
        case .medicalRecord:
            return .medicalRecord(
                recordType: try required("recordType"),
                eventDateUTC: try timestamp("eventDateUTC"),
                title: try required("title")
            )
        case .attachment:
            return .attachment(
                recordID: try uuid("recordID"),
                originalFileID: try uuid("originalFileID"),
                mediaType: try required("mediaType"),
                sha256: try sha256("sha256")
            )
        case .medication:
            return .medication(name: try required("name"))
        case .medicalOrder:
            return .medicalOrder(
                title: try required("title"),
                orderedAtUTC: try timestamp("orderedAtUTC")
            )
        case .followUp:
            return .followUp(
                title: try required("title"),
                dueAtUTC: try timestamp("dueAtUTC"),
                medicalOrderID: try optionalUUID("medicalOrderID")
            )
        case .labMeasurement:
            return .labMeasurement(
                name: try required("name"),
                observedAtUTC: try timestamp("observedAtUTC"),
                recordID: try optionalUUID("recordID")
            )
        case .reminder:
            return .reminder(
                title: try required("title"),
                dueAtUTC: try timestamp("dueAtUTC"),
                reminderKind: try required("kind"),
                medicationID: try optionalUUID("medicationID"),
                recordID: try optionalUUID("recordID")
            )
        case .assignmentAudit:
            return .assignmentAudit(
                action: try required("action"),
                createdAtUTC: try timestamp("createdAtUTC"),
                recordID: try optionalUUID("recordID")
            )
        case .recordTag:
            return .recordTag(
                recordID: try uuid("recordID"),
                name: try required("name")
            )
        case .contentRevision:
            guard let targetKind = TransferEntityKind(
                rawValue: try required("targetKind")
            ), let revision = Int(try required("revision")), revision >= 0 else {
                throw TransferProtocolError.invalidManifest(
                    "invalid content revision"
                )
            }
            return .contentRevision(
                targetEntityID: try uuid("targetEntityID"),
                targetKind: targetKind,
                revision: revision,
                payloadSHA256: try sha256("payloadSHA256")
            )
        }
    }

    static func portablePayload(from fields: [String: String]) throws -> Data? {
        guard let encoded = fields[portablePayloadKey] else { return nil }
        guard !encoded.isEmpty,
              let data = Data(base64Encoded: encoded),
              data.count <= maximumPortablePayloadBytes,
              data.base64EncodedString() == encoded else {
            throw TransferProtocolError.invalidManifest("invalid portable payload")
        }
        return data
    }

    private static func rule(for kind: TransferEntityKind) -> Rule {
        func allowingPortable(_ values: Set<String>) -> Set<String> {
            values.union([portablePayloadKey])
        }
        switch kind {
        case .patient:
            return Rule(
                required: ["displayName"],
                allowed: allowingPortable([
                    "displayName", "reportName", "aliasesJSON", "birthDateUTC",
                    "sex", "notes", "createdAtUTC", "updatedAtUTC", "isArchived"
                ])
            )
        case .medicalRecord:
            return Rule(
                required: ["recordType", "eventDateUTC", "title"],
                allowed: allowingPortable([
                    "recordType", "eventDateUTC", "title", "hospital", "doctor",
                    "disease", "summary", "notes", "createdAtUTC", "updatedAtUTC"
                ])
            )
        case .attachment:
            return Rule(
                required: ["recordID", "originalFileID", "mediaType", "sha256"],
                allowed: allowingPortable([
                    "recordID", "originalFileID", "mediaType", "sha256",
                    "originalFilename", "pageCount", "createdAtUTC"
                ])
            )
        case .medication:
            return Rule(
                required: ["name"],
                allowed: allowingPortable([
                    "name", "dose", "unit", "frequency", "route", "startDateUTC",
                    "endDateUTC", "remainingQuantity", "notes", "updatedAtUTC"
                ])
            )
        case .medicalOrder:
            return Rule(
                required: ["title", "orderedAtUTC"],
                allowed: allowingPortable([
                    "title", "orderedAtUTC", "hospital", "doctor", "notes",
                    "status", "updatedAtUTC"
                ])
            )
        case .followUp:
            return Rule(
                required: ["title", "dueAtUTC"],
                allowed: allowingPortable([
                    "title", "dueAtUTC", "hospital", "doctor", "notes",
                    "status", "medicalOrderID", "updatedAtUTC"
                ])
            )
        case .labMeasurement:
            return Rule(
                required: ["name", "observedAtUTC"],
                allowed: allowingPortable([
                    "name", "observedAtUTC", "numericValue", "textValue", "unit",
                    "referenceRange", "flag", "recordID", "updatedAtUTC"
                ])
            )
        case .reminder:
            return Rule(
                required: ["title", "dueAtUTC", "kind"],
                allowed: allowingPortable([
                    "title", "dueAtUTC", "kind", "status", "notes",
                    "medicationID", "recordID", "updatedAtUTC"
                ])
            )
        case .assignmentAudit:
            return Rule(
                required: ["action", "createdAtUTC"],
                allowed: allowingPortable([
                    "action", "createdAtUTC", "sourcePatientName",
                    "targetPatientID", "reason", "recordID"
                ])
            )
        case .recordTag:
            return Rule(
                required: ["recordID", "name"],
                allowed: allowingPortable([
                    "recordID", "name", "normalizedName", "createdAtUTC"
                ])
            )
        case .contentRevision:
            return Rule(
                required: ["targetEntityID", "targetKind", "revision", "payloadSHA256"],
                allowed: allowingPortable([
                    "targetEntityID", "targetKind", "revision", "payloadSHA256",
                    "createdAtUTC", "reason"
                ])
            )
        }
    }
}

private enum StrictJSONObject {
    @discardableResult
    static func requireKeys(
        in data: Data,
        allowed: Set<String>,
        required: Set<String>
    ) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw TransferProtocolError.invalidManifest("malformed JSON")
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: allowed),
              required.isSubset(of: Set(dictionary.keys)) else {
            throw TransferProtocolError.invalidManifest("unexpected JSON shape")
        }
        return dictionary
    }

    static func requireNestedEnvelopeShape(_ root: [String: Any]) throws {
        guard let references = root["references"] as? [[String: Any]],
              let fields = root["fields"] as? [String: Any] else {
            throw TransferProtocolError.invalidManifest("unexpected JSON shape")
        }
        for reference in references {
            try requireKeys(
                reference,
                allowed: ["entityID", "kind"],
                required: ["entityID", "kind"]
            )
        }
        guard fields.values.allSatisfy({ $0 is String }) else {
            throw TransferProtocolError.invalidManifest("unexpected JSON shape")
        }
    }

    static func requireNestedManifestShape(_ root: [String: Any]) throws {
        guard let scope = root["scope"] as? [String: Any],
              let kind = scope["kind"] as? String,
              let capabilities = root["capabilities"] as? [[String: Any]],
              let preview = root["preview"] as? [String: Any],
              let entities = root["entities"] as? [[String: Any]],
              let files = root["files"] as? [[String: Any]] else {
            throw TransferProtocolError.invalidManifest("unexpected JSON shape")
        }
        switch kind {
        case "singlePatient":
            try requireKeys(
                scope,
                allowed: ["kind", "patientID"],
                required: ["kind", "patientID"]
            )
        case "allPatients":
            try requireKeys(scope, allowed: ["kind"], required: ["kind"])
        default:
            throw TransferProtocolError.invalidManifest("unexpected JSON shape")
        }
        try requireKeys(
            preview,
            allowed: ["memberCount", "recordCount", "attachmentCount"],
            required: ["memberCount", "recordCount", "attachmentCount"]
        )
        for capability in capabilities {
            try requireKeys(
                capability,
                allowed: ["identifier", "version"],
                required: ["identifier", "version"]
            )
        }
        for entity in entities {
            try requireKeys(
                entity,
                allowed: [
                    "kind", "entityID", "patientID", "payloadFileID", "revision"
                ],
                required: [
                    "kind", "entityID", "patientID", "payloadFileID", "revision"
                ]
            )
        }
        for file in files {
            try requireKeys(
                file,
                allowed: [
                    "kind", "fileID", "patientID", "ownerAttachmentID",
                    "relativePath", "byteCount", "sha256", "chunkSize"
                ],
                required: [
                    "kind", "fileID", "patientID", "relativePath",
                    "byteCount", "sha256", "chunkSize"
                ]
            )
        }
    }

    static func requireKeys(
        _ dictionary: [String: Any],
        allowed: Set<String>,
        required: Set<String>
    ) throws {
        let keys = Set(dictionary.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw TransferProtocolError.invalidManifest("unexpected JSON shape")
        }
    }
}

enum TransferProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(offered: Int, minimumReceiver: Int, local: Int)
    case invalidManifest(String)
    case scopeViolation
    case limitExceeded(String)
    case invalidPublicKey
    case authenticationFailed
    case pairingNotConfirmed
    case keyConfirmationFailed
    case transferMismatch
    case fileMismatch
    case invalidChunk(String)
    case outOfOrder(expected: UInt64, received: UInt64)
    case conflictingDuplicate(sequence: UInt64)
    case fileHashMismatch(fileID: UUID)
    case fileSizeMismatch(fileID: UUID)
    case manifestIntegrityFailed
    case missingFile(UUID)
    case invalidStateTransition
    case unsafeStagingPath
    case invalidCommitReceipt
    case transport(String)
    case cancelled
    case entropyUnavailable
    case timedOut(String)
    case uuidConflict(UUID)
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "同步版本不兼容。"
        case let .invalidManifest(reason):
            return "同步清单无效：\(reason)"
        case .scopeViolation:
            return "同步清单包含所选范围之外的成员。"
        case let .limitExceeded(field):
            return "同步内容超过限制：\(field)"
        case .invalidPublicKey:
            return "配对公钥无效。"
        case .authenticationFailed:
            return "同步数据认证失败，可能已被篡改或配对错误。"
        case .pairingNotConfirmed:
            return "必须先在两台设备确认相同配对码。"
        case .keyConfirmationFailed:
            return "同步密钥确认失败。"
        case .transferMismatch:
            return "数据不属于当前同步任务。"
        case .fileMismatch:
            return "数据块不属于当前文件。"
        case let .invalidChunk(reason):
            return "同步数据块无效：\(reason)"
        case let .outOfOrder(expected, received):
            return "同步数据块顺序错误（需要 \(expected)，收到 \(received)）。"
        case let .conflictingDuplicate(sequence):
            return "第 \(sequence) 个重复数据块内容冲突。"
        case .fileHashMismatch:
            return "文件摘要校验失败。"
        case .fileSizeMismatch:
            return "文件大小校验失败。"
        case .manifestIntegrityFailed:
            return "同步清单完整性校验失败。"
        case .missingFile:
            return "同步文件缺失。"
        case .invalidStateTransition:
            return "同步状态转换无效。"
        case .unsafeStagingPath:
            return "同步暂存路径不安全。"
        case .invalidCommitReceipt:
            return "接收端提交回执无效。"
        case let .transport(reason):
            return "附近连接失败：\(reason)"
        case .cancelled:
            return "同步已取消。"
        case .entropyUnavailable:
            return "系统安全随机数不可用，已停止同步。"
        case let .timedOut(operation):
            return "同步步骤超时：\(operation)"
        case .uuidConflict:
            return "导入数据与现有记录标识冲突。"
        case .insufficientStorage:
            return "设备可用空间不足，无法安全暂存同步数据。"
        }
    }
}
