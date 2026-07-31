import Foundation
import SwiftData

enum MedicalRecordSortKey {
    static func title(_ value: String) -> String {
        let canonical = value
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        return canonical.utf8
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
extension CareThreadSchemaV1 {

@Model
final class MedicalRecord {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var typeRawValue: String
    private(set) var title: String
    /// ASCII-only, locale-independent key used by seek pagination. Encoding
    /// normalized UTF-8 bytes as fixed-width hex makes SwiftData sorting and
    /// predicate comparison use the same deterministic collation.
    private(set) var titleSortKey: String = ""
    private(set) var summary: String
    private(set) var eventDate: Date
    private(set) var eventDatePrecisionRawValue: String
    private(set) var eventTimezoneIdentifier: String
    private(set) var hospital: String?
    private(set) var normalizedHospital: String?
    private(set) var department: String?
    private(set) var doctor: String?
    private(set) var normalizedDoctor: String?
    private(set) var primaryDisease: String?
    private(set) var normalizedPrimaryDisease: String?
    private(set) var ageAtEvent: Int?
    private(set) var sourceTypeRawValue: String
    private(set) var ocrText: String?
    private(set) var ocrEngineIdentifier: String?
    private(set) var ocrEngineVersion: String?
    private(set) var extractionSchemaVersion: Int
    private(set) var machineExtractionRevision: Int
    private(set) var confirmedRevision: Int
    private(set) var confirmedAt: Date?
    private(set) var machineExtractionPayload: Data
    private(set) var abnormalFlagsPayload: Data
    private(set) var structuredFieldsPayload: Data
    private(set) var reviewStatusRawValue: String
    private(set) var isKeyRecord: Bool
    private(set) var inBrief: Bool
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    private(set) var contentRevision: Int
    @Relationship(deleteRule: .cascade, inverse: \Attachment.record)
    private(set) var attachments: [Attachment]
    @Relationship(deleteRule: .cascade, inverse: \LabMeasurement.record)
    private(set) var measurements: [LabMeasurement]
    @Relationship(deleteRule: .cascade, inverse: \RecordTag.record)
    private(set) var tags: [RecordTag]

    init(
        id: UUID = UUID(),
        patientId: UUID,
        type: RecordType = .other,
        title: String,
        summary: String = "",
        eventDate: Date,
        eventDatePrecision: EventDatePrecision = .day,
        eventTimezoneIdentifier: String = TimeZone.current.identifier,
        hospital: String? = nil,
        department: String? = nil,
        doctor: String? = nil,
        primaryDisease: String? = nil,
        diseaseTags: [String] = [],
        ageAtEvent: Int? = nil,
        sourceType: SourceType = .manual,
        ocrText: String? = nil,
        ocrEngineIdentifier: String? = nil,
        ocrEngineVersion: String? = nil,
        extractionSchemaVersion: Int = 1,
        machineExtractionRevision: Int = 0,
        confirmedRevision: Int = 0,
        confirmedAt: Date? = nil,
        machineExtraction: ExtractionResult? = nil,
        labItems: [LabItem] = [],
        abnormalFlags: [String] = [],
        structuredFields: [KeyValueItem] = [],
        reviewStatus: ReviewStatus = .pending,
        isKeyRecord: Bool = false,
        inBrief: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.patientId = patientId
        self.typeRawValue = type.rawValue
        self.title = title
        self.titleSortKey = MedicalRecordSortKey.title(title)
        self.summary = summary
        self.eventDate = eventDate
        self.eventDatePrecisionRawValue = eventDatePrecision.rawValue
        self.eventTimezoneIdentifier = eventTimezoneIdentifier
        self.hospital = MemberIdentity.optionalTrimmed(hospital)
        self.normalizedHospital = MemberIdentity.normalizedOptional(hospital)
        self.department = MemberIdentity.optionalTrimmed(department)
        self.doctor = MemberIdentity.optionalTrimmed(doctor)
        self.normalizedDoctor = MemberIdentity.normalizedOptional(doctor)
        self.primaryDisease = MemberIdentity.optionalTrimmed(primaryDisease)
        self.normalizedPrimaryDisease = MemberIdentity.normalizedOptional(primaryDisease)
        self.ageAtEvent = ageAtEvent
        self.sourceTypeRawValue = sourceType.rawValue
        self.ocrText = ocrText
        self.ocrEngineIdentifier = ocrEngineIdentifier ?? machineExtraction?.engineIdentifier
        self.ocrEngineVersion = ocrEngineVersion
        self.extractionSchemaVersion = extractionSchemaVersion
        self.machineExtractionRevision = machineExtractionRevision
        self.confirmedRevision = confirmedRevision
        self.confirmedAt = confirmedAt
        self.machineExtractionPayload = ModelPayload.requiredEncodeOptional(machineExtraction)
        self.abnormalFlagsPayload = ModelPayload.requiredEncode(abnormalFlags)
        self.structuredFieldsPayload = ModelPayload.requiredEncode(structuredFields)
        self.reviewStatusRawValue = reviewStatus.rawValue
        self.isKeyRecord = isKeyRecord
        self.inBrief = inBrief
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.contentRevision = 0
        self.attachments = []
        self.measurements = []
        self.tags = []
        self.measurements = labItems.map {
            LabMeasurement(patientId: patientId, recordId: id, item: $0, eventDate: eventDate)
        }
        self.tags = diseaseTags.map {
            RecordTag(patientId: patientId, recordId: id, kind: .disease, displayValue: $0)
        }
        attachments.forEach {
            precondition(
                $0.patientId == patientId && ($0.recordId == nil || $0.recordId == id),
                "Attachment graph scope mismatch"
            )
            $0.bindUnchecked(to: self)
        }
        self.attachments = attachments
    }

    private(set) var type: RecordType {
        get { RecordType(rawValue: typeRawValue) ?? .other }
        set { typeRawValue = newValue.rawValue; updatedAt = Date() }
    }

    private(set) var eventDatePrecision: EventDatePrecision {
        get { EventDatePrecision(rawValue: eventDatePrecisionRawValue) ?? .unknown }
        set { eventDatePrecisionRawValue = newValue.rawValue; updatedAt = Date() }
    }

    private(set) var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRawValue) ?? .manual }
        set { sourceTypeRawValue = newValue.rawValue; updatedAt = Date() }
    }

    private(set) var machineExtraction: ExtractionResult? {
        get { ModelPayload.decodeOptional(ExtractionResult.self, from: machineExtractionPayload) }
        set {
            machineExtractionPayload = ModelPayload.requiredEncodeOptional(newValue)
            ocrEngineIdentifier = newValue?.engineIdentifier ?? ocrEngineIdentifier
            machineExtractionRevision += 1
            updatedAt = Date()
        }
    }

    var labItems: [LabItem] {
        measurements.compactMap(\.labItem)
    }

    private(set) var abnormalFlags: [String] {
        get { ModelPayload.decode([String].self, from: abnormalFlagsPayload, fallback: []) }
        set { abnormalFlagsPayload = ModelPayload.requiredEncode(newValue); updatedAt = Date() }
    }

    private(set) var structuredFields: [KeyValueItem] {
        get { ModelPayload.decode([KeyValueItem].self, from: structuredFieldsPayload, fallback: []) }
        set { structuredFieldsPayload = ModelPayload.requiredEncode(newValue); updatedAt = Date() }
    }

    private(set) var reviewStatus: ReviewStatus {
        get { ReviewStatus(rawValue: reviewStatusRawValue) ?? .pending }
        set { reviewStatusRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var diseaseTags: [String] {
        tags.filter { $0.kind == .disease }.map(\.displayValue)
    }

    fileprivate func updateSearchFields(hospital: String?, doctor: String?, primaryDisease: String?) {
        self.hospital = MemberIdentity.optionalTrimmed(hospital)
        self.normalizedHospital = MemberIdentity.normalizedOptional(hospital)
        self.doctor = MemberIdentity.optionalTrimmed(doctor)
        self.normalizedDoctor = MemberIdentity.normalizedOptional(doctor)
        self.primaryDisease = MemberIdentity.optionalTrimmed(primaryDisease)
        self.normalizedPrimaryDisease = MemberIdentity.normalizedOptional(primaryDisease)
        self.updatedAt = Date()
    }

    fileprivate func updateEventDate(
        _ eventDate: Date,
        precision: EventDatePrecision,
        timezoneIdentifier: String,
        ageAtEvent: Int?
    ) {
        self.eventDate = eventDate
        self.eventDatePrecisionRawValue = precision.rawValue
        self.eventTimezoneIdentifier = timezoneIdentifier
        self.ageAtEvent = ageAtEvent
        measurements.forEach { $0.synchronizeEventDate(eventDate) }
        self.updatedAt = Date()
    }

    func validateGraph() throws {
        for attachment in attachments {
            guard attachment.patientId == patientId else {
                throw RecordGraphValidationError.attachmentScope
            }
            guard attachment.recordId == id, attachment.record == nil || attachment.record === self else {
                throw RecordGraphValidationError.attachmentRecord
            }
            guard attachment.isStoredWithin(
                patientId: patientId,
                recordId: id
            ) else {
                throw RecordGraphValidationError.attachmentScope
            }
        }
        for measurement in measurements {
            guard measurement.patientId == patientId else {
                throw RecordGraphValidationError.measurementScope
            }
            guard measurement.recordId == id, measurement.record == nil || measurement.record === self else {
                throw RecordGraphValidationError.measurementRecord
            }
        }
        for tag in tags {
            guard tag.patientId == patientId else {
                throw RecordGraphValidationError.tagScope
            }
            guard tag.recordId == id, tag.record == nil || tag.record === self else {
                throw RecordGraphValidationError.tagRecord
            }
        }
    }

    func bindAttachment(_ attachment: Attachment) throws {
        try attachment.bind(to: self)
        attachments.append(attachment)
        updatedAt = Date()
    }

    @discardableResult
    func replaceAttachments(with replacements: [Attachment]) throws -> [Attachment] {
        for attachment in replacements {
            try attachment.bind(to: self)
        }
        let removed = attachments.filter { existing in
            !replacements.contains { $0.id == existing.id }
        }
        attachments = replacements
        updatedAt = Date()
        return removed
    }

    @discardableResult
    func replaceMeasurements(with replacements: [LabMeasurement]) throws -> [LabMeasurement] {
        for measurement in replacements {
            try measurement.bind(to: self)
        }
        let removed = measurements.filter { existing in
            !replacements.contains { $0.id == existing.id }
        }
        measurements = replacements
        updatedAt = Date()
        return removed
    }

    @discardableResult
    func replaceTags(with replacements: [RecordTag]) throws -> [RecordTag] {
        for tag in replacements {
            try tag.bind(to: self)
        }
        let removed = tags.filter { existing in
            !replacements.contains { $0.id == existing.id }
        }
        tags = replacements
        updatedAt = Date()
        return removed
    }
}

@Model
final class Attachment {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var recordId: UUID?
    private(set) var originalRelativePath: String
    private(set) var derivedRelativePath: String?
    /// Original user-facing source filename, never a Vault path.
    private(set) var displayFileName: String
    private(set) var uniformTypeIdentifier: String
    private(set) var byteCount: Int64
    private(set) var sha256: String
    private(set) var importedAt: Date
    private(set) var importSourceRawValue: String
    var pixelWidth: Int?
    var pixelHeight: Int?
    var pageCount: Int?
    private(set) var integrityStateRawValue: String
    private(set) var kindRawValue: String
    var pageIndex: Int
    private(set) var record: MedicalRecord?

    init(
        id: UUID = UUID(),
        patientId: UUID,
        fileName: String,
        originalFileName: String? = nil,
        kind: AttachmentKind,
        pageIndex: Int,
        record: MedicalRecord? = nil,
        recordId: UUID? = nil,
        displayFileName: String? = nil,
        uniformTypeIdentifier: String = "public.data",
        byteCount: Int64 = 0,
        sha256: String = "",
        importedAt: Date = Date(),
        importSource: ImportSource = .files,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        pageCount: Int? = nil,
        integrityState: AttachmentIntegrityState = .pending
    ) {
        self.id = id
        self.patientId = patientId
        self.recordId = recordId ?? record?.id
        self.originalRelativePath = originalFileName ?? fileName
        self.derivedRelativePath = originalFileName == nil ? nil : fileName
        self.displayFileName = displayFileName ?? URL(fileURLWithPath: fileName).lastPathComponent
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
        self.importedAt = importedAt
        self.importSourceRawValue = importSource.rawValue
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pageCount = pageCount
        self.integrityStateRawValue = integrityState.rawValue
        self.kindRawValue = kind.rawValue
        self.pageIndex = pageIndex
        self.record = record
    }

    /// Compatibility path used by the current viewer/repository.
    var fileName: String {
        derivedRelativePath ?? originalRelativePath
    }

    var originalFileName: String? {
        originalRelativePath
    }

    var kind: AttachmentKind {
        AttachmentKind(rawValue: kindRawValue) ?? .image
    }

    var importSource: ImportSource {
        ImportSource(rawValue: importSourceRawValue) ?? .files
    }

    var integrityState: AttachmentIntegrityState {
        AttachmentIntegrityState(rawValue: integrityStateRawValue) ?? .pending
    }

    static func verified(
        id: UUID = UUID(),
        patientId: UUID,
        recordId: UUID? = nil,
        originalRelativePath: String,
        derivedRelativePath: String? = nil,
        displayFileName: String,
        kind: AttachmentKind,
        pageIndex: Int,
        uniformTypeIdentifier: String,
        byteCount: Int64,
        sha256: String,
        importedAt: Date = Date(),
        importSource: ImportSource,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        pageCount: Int? = nil
    ) throws -> Attachment {
        try validateRelativePath(originalRelativePath)
        if let derivedRelativePath {
            try validateRelativePath(derivedRelativePath)
        }
        guard !displayFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentValidationError.missingDisplayFileName
        }
        guard !uniformTypeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentValidationError.missingTypeIdentifier
        }
        guard byteCount > 0 else {
            throw AttachmentValidationError.emptyContent
        }
        let shaPattern = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{64}$")
        let range = NSRange(sha256.startIndex..<sha256.endIndex, in: sha256)
        guard shaPattern.firstMatch(in: sha256, range: range) != nil else {
            throw AttachmentValidationError.invalidSHA256
        }
        guard let recordId,
              storagePathMatches(
                originalRelativePath,
                patientId: patientId,
                recordId: recordId,
                attachmentId: id,
                expectedStem: "original"
              ),
              derivedRelativePath.map({
                  storagePathMatches(
                      $0,
                      patientId: patientId,
                      recordId: recordId,
                      attachmentId: id,
                      expectedStem: "preview"
                  )
              }) ?? true else {
            throw AttachmentValidationError.invalidRelativePath
        }
        return Attachment(
            id: id,
            patientId: patientId,
            fileName: derivedRelativePath ?? originalRelativePath,
            originalFileName: derivedRelativePath == nil ? nil : originalRelativePath,
            kind: kind,
            pageIndex: pageIndex,
            recordId: recordId,
            displayFileName: displayFileName,
            uniformTypeIdentifier: uniformTypeIdentifier,
            byteCount: byteCount,
            sha256: sha256.lowercased(),
            importedAt: importedAt,
            importSource: importSource,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pageCount: pageCount,
            integrityState: .verified
        )
    }

    func bind(to record: MedicalRecord) throws {
        guard patientId == record.patientId else {
            throw RecordGraphValidationError.attachmentScope
        }
        guard recordId == nil || recordId == record.id else {
            throw RecordGraphValidationError.attachmentRecord
        }
        guard self.record == nil || self.record === record else {
            throw RecordGraphValidationError.attachmentRecord
        }
        guard isStoredWithin(
            patientId: record.patientId,
            recordId: record.id
        ) else {
            throw RecordGraphValidationError.attachmentScope
        }
        bindUnchecked(to: record)
    }

    fileprivate func bindUnchecked(to record: MedicalRecord) {
        recordId = record.id
        self.record = record
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw AttachmentValidationError.invalidRelativePath
        }
        let components = NSString(string: path).pathComponents
        guard !components.contains(".."), !components.contains("."), !components.contains("/") else {
            throw AttachmentValidationError.invalidRelativePath
        }
    }

    fileprivate func isStoredWithin(
        patientId: UUID,
        recordId: UUID
    ) -> Bool {
        Self.storagePathMatches(
            originalRelativePath,
            patientId: patientId,
            recordId: recordId,
            attachmentId: id,
            expectedStem: "original"
        ) && (derivedRelativePath.map {
            Self.storagePathMatches(
                $0,
                patientId: patientId,
                recordId: recordId,
                attachmentId: id,
                expectedStem: "preview"
            )
        } ?? true)
    }

    private static func storagePathMatches(
        _ path: String,
        patientId: UUID,
        recordId: UUID,
        attachmentId: UUID,
        expectedStem: String
    ) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 7,
              components[0] == "members",
              components[1] == patientId.uuidString,
              components[2] == "records",
              components[3] == recordId.uuidString,
              components[4] == "attachments",
              components[5] == attachmentId.uuidString else {
            return false
        }
        let fileName = String(components[6])
        guard !fileName.isEmpty else { return false }
        if expectedStem == "preview" {
            return fileName == "preview.jpg"
        }
        return fileName.hasPrefix("\(expectedStem).")
            && fileName.count > expectedStem.count + 1
    }
}

@Model
final class LabMeasurement {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var recordId: UUID
    private(set) var normalizedName: String
    private(set) var displayName: String
    private(set) var numericValue: Double?
    private(set) var textualValue: String?
    private(set) var unit: String
    private(set) var referenceLow: Double?
    private(set) var referenceHigh: Double?
    private(set) var referenceText: String?
    private(set) var abnormalStateRawValue: String
    private(set) var confidenceRawValue: String
    private(set) var eventDate: Date
    private(set) var contentRevision: Int
    private(set) var record: MedicalRecord?

    init(
        id: UUID = UUID(),
        patientId: UUID,
        recordId: UUID,
        normalizedName: String? = nil,
        displayName: String,
        numericValue: Double? = nil,
        textualValue: String? = nil,
        unit: String = "",
        referenceLow: Double? = nil,
        referenceHigh: Double? = nil,
        referenceText: String? = nil,
        abnormalState: LabFlag = .none,
        confidence: Confidence = .high,
        eventDate: Date,
        record: MedicalRecord? = nil
    ) {
        self.id = id
        self.patientId = patientId
        self.recordId = recordId
        self.normalizedName = normalizedName ?? MemberIdentity.normalize(displayName)
        self.displayName = displayName
        self.numericValue = numericValue
        self.textualValue = textualValue
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.referenceText = referenceText
        self.abnormalStateRawValue = abnormalState.rawValue
        self.confidenceRawValue = confidence.rawValue
        self.eventDate = eventDate
        self.contentRevision = 0
        self.record = record
    }

    convenience init(patientId: UUID, recordId: UUID, item: LabItem, eventDate: Date) {
        self.init(
            id: item.id,
            patientId: patientId,
            recordId: recordId,
            displayName: item.name,
            numericValue: item.value,
            unit: item.unit,
            referenceLow: item.refLow,
            referenceHigh: item.refHigh,
            abnormalState: item.flag,
            confidence: item.confidence,
            eventDate: eventDate
        )
    }

    var abnormalState: LabFlag {
        LabFlag(rawValue: abnormalStateRawValue) ?? .none
    }

    var confidence: Confidence {
        Confidence(rawValue: confidenceRawValue) ?? .low
    }

    var labItem: LabItem? {
        guard let numericValue else { return nil }
        return LabItem(
            id: id,
            name: displayName,
            value: numericValue,
            unit: unit,
            refLow: referenceLow,
            refHigh: referenceHigh,
            flag: abnormalState,
            confidence: confidence
        )
    }

    func bind(to record: MedicalRecord) throws {
        guard patientId == record.patientId else {
            throw RecordGraphValidationError.measurementScope
        }
        guard recordId == record.id, self.record == nil || self.record === record else {
            throw RecordGraphValidationError.measurementRecord
        }
        self.record = record
    }

    fileprivate func synchronizeEventDate(_ eventDate: Date) {
        self.eventDate = eventDate
    }
}

@Model
final class RecordTag {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var recordId: UUID
    private(set) var kindRawValue: String
    private(set) var normalizedValue: String
    private(set) var displayValue: String
    private(set) var record: MedicalRecord?
    private(set) var contentRevision: Int

    init(
        id: UUID = UUID(),
        patientId: UUID,
        recordId: UUID,
        kind: RecordTagKind,
        displayValue: String,
        record: MedicalRecord? = nil
    ) {
        self.id = id
        self.patientId = patientId
        self.recordId = recordId
        self.kindRawValue = kind.rawValue
        self.normalizedValue = MemberIdentity.normalize(displayValue)
        self.displayValue = displayValue
        self.record = record
        self.contentRevision = 0
    }

    var kind: RecordTagKind {
        RecordTagKind(rawValue: kindRawValue) ?? .custom
    }

    func bind(to record: MedicalRecord) throws {
        guard patientId == record.patientId else {
            throw RecordGraphValidationError.tagScope
        }
        guard recordId == record.id, self.record == nil || self.record === record else {
            throw RecordGraphValidationError.tagRecord
        }
        self.record = record
    }
}

/// Append-only audit event. Callers create a new row for every decision and do
/// not update an existing instance.

}

extension MedicalRecord: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .medicalRecord
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> MedicalRecordEditableContent {
        MedicalRecordEditableContent(
            type: type,
            title: title,
            summary: summary,
            eventDate: eventDate,
            eventDatePrecision: eventDatePrecision,
            eventTimezoneIdentifier: eventTimezoneIdentifier,
            hospital: hospital,
            department: department,
            doctor: doctor,
            primaryDisease: primaryDisease,
            ageAtEvent: ageAtEvent,
            abnormalFlags: abnormalFlags,
            structuredFields: structuredFields,
            reviewStatus: reviewStatus,
            isKeyRecord: isKeyRecord,
            inBrief: inBrief,
            confirmedRevision: confirmedRevision,
            confirmedAt: confirmedAt,
            updatedAt: updatedAt
        )
    }

    func applyEditableContent(_ content: MedicalRecordEditableContent) {
        typeRawValue = content.type.rawValue
        title = content.title
        titleSortKey = MedicalRecordSortKey.title(content.title)
        summary = content.summary
        updateEventDate(
            content.eventDate,
            precision: content.eventDatePrecision,
            timezoneIdentifier: content.eventTimezoneIdentifier,
            ageAtEvent: content.ageAtEvent
        )
        updateSearchFields(
            hospital: content.hospital,
            doctor: content.doctor,
            primaryDisease: content.primaryDisease
        )
        department = MemberIdentity.optionalTrimmed(content.department)
        abnormalFlagsPayload = ModelPayload.requiredEncode(content.abnormalFlags)
        structuredFieldsPayload = ModelPayload.requiredEncode(content.structuredFields)
        reviewStatusRawValue = content.reviewStatus.rawValue
        isKeyRecord = content.isKeyRecord
        inBrief = content.inBrief
        confirmedRevision = content.confirmedRevision
        confirmedAt = content.confirmedAt
        updatedAt = content.updatedAt
    }

    func bumpContentRevision() {
        contentRevision += 1
        confirmedRevision += 1
        confirmedAt = Date()
        updatedAt = Date()
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}

extension LabMeasurement: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .labMeasurement
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> LabMeasurementEditableContent {
        LabMeasurementEditableContent(
            displayName: displayName,
            numericValue: numericValue,
            textualValue: textualValue,
            unit: unit,
            referenceLow: referenceLow,
            referenceHigh: referenceHigh,
            referenceText: referenceText,
            abnormalState: abnormalState,
            confidence: confidence,
            eventDate: eventDate
        )
    }

    func applyEditableContent(_ content: LabMeasurementEditableContent) {
        displayName = content.displayName
        normalizedName = MemberIdentity.normalize(content.displayName)
        numericValue = content.numericValue
        textualValue = content.textualValue
        unit = content.unit
        referenceLow = content.referenceLow
        referenceHigh = content.referenceHigh
        referenceText = content.referenceText
        abnormalStateRawValue = content.abnormalState.rawValue
        confidenceRawValue = content.confidence.rawValue
        eventDate = content.eventDate
    }

    func bumpContentRevision() {
        contentRevision += 1
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}

extension RecordTag: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .recordTag
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> RecordTagEditableContent {
        RecordTagEditableContent(kind: kind, displayValue: displayValue)
    }

    func applyEditableContent(_ content: RecordTagEditableContent) {
        kindRawValue = content.kind.rawValue
        displayValue = content.displayValue
        normalizedValue = MemberIdentity.normalize(content.displayValue)
    }

    func bumpContentRevision() {
        contentRevision += 1
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}
