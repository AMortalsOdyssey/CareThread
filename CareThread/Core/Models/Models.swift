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
final class Patient {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var displayName: String
    private(set) var reportName: String?
    private(set) var aliasesPayload: Data
    private(set) var normalizedAliasesPayload: Data
    private(set) var normalizedSearchText: String
    private(set) var birthDate: Date?
    private(set) var gender: String?
    private(set) var conditionsPayload: Data
    private(set) var allergiesPayload: Data
    private(set) var historiesPayload: Data
    private(set) var careQuestionsPayload: Data = Data()
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    private(set) var contentRevision: Int

    init(
        id: UUID = UUID(),
        name: String = "我的档案",
        displayName: String? = nil,
        reportName: String? = nil,
        aliases: [String] = [],
        birthday: Date? = nil,
        birthDate: Date? = nil,
        gender: String? = nil,
        conditions: [String] = [],
        allergies: [String] = [],
        histories: [HistoryItem] = [],
        careQuestions: [CareQuestion] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        let resolvedDisplayName = MemberIdentity.normalizedDisplayName(displayName ?? name)
        let resolvedAliases = aliases.compactMap(MemberIdentity.optionalTrimmed)
        let normalizedAliases = MemberIdentity.normalizedEvidenceAliases(
            reportName: reportName,
            aliases: resolvedAliases
        )
        self.id = id
        self.displayName = resolvedDisplayName
        self.reportName = MemberIdentity.optionalTrimmed(reportName)
        self.aliasesPayload = ModelPayload.requiredEncode(resolvedAliases)
        self.normalizedAliasesPayload = ModelPayload.requiredEncode(normalizedAliases)
        self.normalizedSearchText = MemberIdentity.searchText(
            displayName: resolvedDisplayName,
            evidenceAliases: normalizedAliases
        )
        self.birthDate = birthDate ?? birthday
        self.gender = gender
        self.conditionsPayload = ModelPayload.requiredEncode(conditions)
        self.allergiesPayload = ModelPayload.requiredEncode(allergies)
        self.historiesPayload = ModelPayload.requiredEncode(histories)
        self.careQuestionsPayload = ModelPayload.requiredEncode(careQuestions)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.contentRevision = 0
    }

    /// Compatibility facade for the original single-member model.
    private(set) var name: String {
        get { displayName }
        set { updateIdentity(displayName: newValue, reportName: reportName, aliases: aliases) }
    }

    private(set) var birthday: Date? {
        get { birthDate }
        set { birthDate = newValue; updatedAt = Date() }
    }

    private(set) var aliases: [String] {
        get { ModelPayload.decode([String].self, from: aliasesPayload, fallback: []) }
        set { updateIdentity(displayName: displayName, reportName: reportName, aliases: newValue) }
    }

    var normalizedAliases: [String] {
        ModelPayload.decode([String].self, from: normalizedAliasesPayload, fallback: [])
    }

    private(set) var conditions: [String] {
        get { ModelPayload.decode([String].self, from: conditionsPayload, fallback: []) }
        set { conditionsPayload = ModelPayload.requiredEncode(newValue); updatedAt = Date() }
    }

    private(set) var allergies: [String] {
        get { ModelPayload.decode([String].self, from: allergiesPayload, fallback: []) }
        set { allergiesPayload = ModelPayload.requiredEncode(newValue); updatedAt = Date() }
    }

    private(set) var histories: [HistoryItem] {
        get { ModelPayload.decode([HistoryItem].self, from: historiesPayload, fallback: []) }
        set { historiesPayload = ModelPayload.requiredEncode(newValue); updatedAt = Date() }
    }

    private(set) var careQuestions: [CareQuestion] {
        get {
            ModelPayload.decode(
                [CareQuestion].self,
                from: careQuestionsPayload,
                fallback: []
            )
        }
        set {
            careQuestionsPayload = ModelPayload.requiredEncode(newValue)
            updatedAt = Date()
        }
    }

    fileprivate func updateIdentity(displayName: String, reportName: String?, aliases: [String]) {
        let resolvedDisplayName = MemberIdentity.normalizedDisplayName(displayName)
        let resolvedReportName = MemberIdentity.optionalTrimmed(reportName)
        let resolvedAliases = aliases.compactMap(MemberIdentity.optionalTrimmed)
        let normalized = MemberIdentity.normalizedEvidenceAliases(
            reportName: resolvedReportName,
            aliases: resolvedAliases
        )
        self.displayName = resolvedDisplayName
        self.reportName = resolvedReportName
        self.aliasesPayload = ModelPayload.requiredEncode(resolvedAliases)
        self.normalizedAliasesPayload = ModelPayload.requiredEncode(normalized)
        self.normalizedSearchText = MemberIdentity.searchText(
            displayName: resolvedDisplayName,
            evidenceAliases: normalized
        )
        self.updatedAt = Date()
    }
}

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
final class Medication {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var name: String
    private(set) var doseValue: Double?
    private(set) var doseUnit: String
    private(set) var frequencyRawValue: String
    private(set) var weeklyCount: Int?
    private(set) var usageNotesPayload: Data
    private(set) var startDate: Date
    /// Exclusive upper bound. A nil value means there is no scheduled end.
    private(set) var endDate: Date?
    private(set) var isLongTerm: Bool
    private(set) var hospital: String?
    private(set) var department: String?
    private(set) var linkedDiagnosis: String?
    private(set) var caution: String?
    private(set) var sourceRecordId: UUID?
    private(set) var previousVersionId: UUID?
    private(set) var reminderEnabled: Bool
    private(set) var reminderTimesPayload: Data
    private(set) var remainingQuantity: Double?
    private(set) var refillReminderAt: Date?
    private(set) var lifecycleStatusRawValue: String
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    private(set) var contentRevision: Int

    init(
        id: UUID = UUID(),
        patientId: UUID,
        name: String,
        doseValue: Double? = nil,
        doseUnit: String = "",
        frequency: FrequencyPreset = .dailyOne,
        weeklyCount: Int? = nil,
        usageNotes: [String] = [],
        startDate: Date,
        endDate: Date? = nil,
        isLongTerm: Bool = true,
        hospital: String? = nil,
        department: String? = nil,
        linkedDiagnosis: String? = nil,
        caution: String? = nil,
        sourceRecordId: UUID? = nil,
        previousVersionId: UUID? = nil,
        reminderEnabled: Bool = false,
        reminderTimes: [ReminderTime] = [],
        remainingQuantity: Double? = nil,
        refillReminderAt: Date? = nil,
        lifecycleStatus: MedicationLifecycleStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        contentRevision: Int = 0
    ) {
        self.id = id
        self.patientId = patientId
        self.name = name
        self.doseValue = doseValue
        self.doseUnit = doseUnit
        self.frequencyRawValue = frequency.rawValue
        self.weeklyCount = weeklyCount
        self.usageNotesPayload = ModelPayload.requiredEncode(usageNotes)
        self.startDate = startDate
        self.endDate = endDate
        self.isLongTerm = isLongTerm
        self.hospital = hospital
        self.department = department
        self.linkedDiagnosis = linkedDiagnosis
        self.caution = caution
        self.sourceRecordId = sourceRecordId
        self.previousVersionId = previousVersionId
        self.reminderEnabled = reminderEnabled
        self.reminderTimesPayload = ModelPayload.requiredEncode(reminderTimes)
        self.remainingQuantity = remainingQuantity
        self.refillReminderAt = refillReminderAt
        self.lifecycleStatusRawValue = lifecycleStatus.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.contentRevision = max(0, contentRevision)
    }

    private(set) var frequency: FrequencyPreset {
        get { FrequencyPreset(rawValue: frequencyRawValue) ?? .dailyOne }
        set { frequencyRawValue = newValue.rawValue }
    }

    private(set) var usageNotes: [String] {
        get { ModelPayload.decode([String].self, from: usageNotesPayload, fallback: []) }
        set { usageNotesPayload = ModelPayload.requiredEncode(newValue) }
    }

    private(set) var reminderTimes: [ReminderTime] {
        get { ModelPayload.decode([ReminderTime].self, from: reminderTimesPayload, fallback: []) }
        set { reminderTimesPayload = ModelPayload.requiredEncode(newValue) }
    }

    var lifecycleStatus: MedicationLifecycleStatus {
        MedicationLifecycleStatus(rawValue: lifecycleStatusRawValue) ?? .active
    }

    /// Uses half-open interval semantics: `startDate <= date < endDate`.
    func isEffective(at date: Date) -> Bool {
        guard date >= startDate else { return false }
        return endDate.map { date < $0 } ?? true
    }
}

@Model
final class MedicalOrder {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var content: String
    private(set) var sourceRecordId: UUID?
    private(set) var generatedFollowUpId: UUID?
    private(set) var isCompleted: Bool
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    private(set) var contentRevision: Int

    init(
        id: UUID = UUID(),
        patientId: UUID,
        content: String,
        sourceRecordId: UUID? = nil,
        generatedFollowUpId: UUID? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        contentRevision: Int = 0
    ) {
        self.id = id
        self.patientId = patientId
        self.content = content
        self.sourceRecordId = sourceRecordId
        self.generatedFollowUpId = generatedFollowUpId
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.contentRevision = max(0, contentRevision)
    }

    func linkGeneratedFollowUp(
        _ followUpId: UUID?,
        updatedAt: Date
    ) {
        generatedFollowUpId = followUpId
        self.updatedAt = updatedAt
    }
}

@Model
final class FollowUp {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var sourceOrderId: UUID?
    private(set) var plannedDate: Date
    private(set) var itemsPayload: Data
    private(set) var reason: String?
    private(set) var bringRecordIdsPayload: Data
    private(set) var compareRecordId: UUID?
    private(set) var statusRawValue: String
    private(set) var completedAt: Date?
    private(set) var resultRecordId: UUID?
    private(set) var reminderEnabled: Bool
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    private(set) var contentRevision: Int

    init(
        id: UUID = UUID(),
        patientId: UUID,
        sourceOrderId: UUID? = nil,
        plannedDate: Date,
        items: [String],
        reason: String? = nil,
        bringRecordIds: [UUID] = [],
        compareRecordId: UUID? = nil,
        status: FollowUpStatus = .pending,
        completedAt: Date? = nil,
        resultRecordId: UUID? = nil,
        reminderEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        contentRevision: Int = 0
    ) {
        self.id = id
        self.patientId = patientId
        self.sourceOrderId = sourceOrderId
        self.plannedDate = plannedDate
        self.itemsPayload = ModelPayload.requiredEncode(items)
        self.reason = reason
        self.bringRecordIdsPayload = ModelPayload.requiredEncode(bringRecordIds)
        self.compareRecordId = compareRecordId
        self.statusRawValue = status.rawValue
        self.completedAt = completedAt
        self.resultRecordId = resultRecordId
        self.reminderEnabled = reminderEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.contentRevision = max(0, contentRevision)
    }

    private(set) var items: [String] {
        get { ModelPayload.decode([String].self, from: itemsPayload, fallback: []) }
        set { itemsPayload = ModelPayload.requiredEncode(newValue) }
    }

    private(set) var bringRecordIds: [UUID] {
        get { ModelPayload.decode([UUID].self, from: bringRecordIdsPayload, fallback: []) }
        set { bringRecordIdsPayload = ModelPayload.requiredEncode(newValue) }
    }

    private(set) var status: FollowUpStatus {
        get { FollowUpStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }
}

@Model
final class ImportBatch {
    @Attribute(.unique) private(set) var id: UUID
    /// Frozen when the import starts.
    private(set) var patientId: UUID
    private(set) var sourceTypeRawValue: String
    private(set) var statusRawValue: String
    private(set) var generation: Int
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \CaptureDraft.batch)
    private(set) var drafts: [CaptureDraft]

    init(
        id: UUID = UUID(),
        patientId: UUID,
        sourceType: SourceType,
        status: ImportBatchStatus = .staging,
        generation: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.patientId = patientId
        self.sourceTypeRawValue = sourceType.rawValue
        self.statusRawValue = status.rawValue
        self.generation = max(0, generation)
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.drafts = []
    }

    var sourceType: SourceType {
        SourceType(rawValue: sourceTypeRawValue) ?? .file
    }

    var status: ImportBatchStatus {
        ImportBatchStatus(rawValue: statusRawValue) ?? .failed
    }

    func bindDraft(_ draft: CaptureDraft) throws {
        try draft.bind(to: self)
        guard !drafts.contains(where: { $0.id == draft.id }) else { return }
        drafts.append(draft)
        drafts.sort {
            ($0.documentIndex, $0.id.uuidString) < ($1.documentIndex, $1.id.uuidString)
        }
        updatedAt = Date()
    }

    func advance(to status: ImportBatchStatus) {
        statusRawValue = status.rawValue
        generation += 1
        updatedAt = Date()
    }

    var state: ImportBatchState {
        ImportBatchState(status: status, generation: generation, updatedAt: updatedAt)
    }

    func markDocumentCommitted(remainingDocumentCount: Int) {
        statusRawValue = remainingDocumentCount == 0
            ? ImportBatchStatus.completed.rawValue
            : ImportBatchStatus.partiallyCommitted.rawValue
        generation += 1
        updatedAt = Date()
    }

    func restoreState(_ state: ImportBatchState) {
        statusRawValue = state.status.rawValue
        generation = state.generation
        updatedAt = state.updatedAt
    }
}

@Model
final class CaptureDraft {
    @Attribute(.unique) private(set) var id: UUID
    /// Frozen at capture start. Switching the visible member never mutates it.
    private(set) var patientId: UUID
    private(set) var batchId: UUID
    private(set) var documentIndex: Int
    private(set) var groupingRevision: Int
    private(set) var generation: Int
    private(set) var titleSuggestion: String?
    private(set) var confirmedTitle: String?
    private(set) var sourceTypeRawValue: String
    private(set) var attachmentPathsPayload: Data
    private(set) var selectedTypeRawValue: String?
    private(set) var selectedDate: Date?
    private(set) var ocrText: String?
    private(set) var machineExtractionPayload: Data
    private(set) var updatedAt: Date
    private(set) var contentRevision: Int
    private(set) var batch: ImportBatch?
    @Relationship(deleteRule: .cascade, inverse: \CapturePage.draft)
    private(set) var pages: [CapturePage]

    init(
        id: UUID = UUID(),
        patientId: UUID,
        batchId: UUID,
        documentIndex: Int,
        groupingRevision: Int = 0,
        generation: Int = 0,
        titleSuggestion: String? = nil,
        confirmedTitle: String? = nil,
        sourceType: SourceType,
        attachmentPaths: [String] = [],
        selectedType: RecordType? = nil,
        selectedDate: Date? = nil,
        ocrText: String? = nil,
        machineExtraction: ExtractionResult? = nil,
        updatedAt: Date = Date(),
        batch: ImportBatch? = nil
    ) {
        precondition(documentIndex >= 0, "Capture document index must be non-negative")
        self.id = id
        self.patientId = patientId
        self.batchId = batchId
        self.documentIndex = documentIndex
        self.groupingRevision = max(0, groupingRevision)
        self.generation = max(0, generation)
        self.titleSuggestion = MemberIdentity.optionalTrimmed(titleSuggestion)
        self.confirmedTitle = MemberIdentity.optionalTrimmed(confirmedTitle)
        self.sourceTypeRawValue = sourceType.rawValue
        self.attachmentPathsPayload = ModelPayload.requiredEncode(attachmentPaths)
        self.selectedTypeRawValue = selectedType?.rawValue
        self.selectedDate = selectedDate
        self.ocrText = ocrText
        self.machineExtractionPayload = ModelPayload.requiredEncodeOptional(machineExtraction)
        self.updatedAt = updatedAt
        self.contentRevision = 0
        self.batch = batch
        self.pages = []
    }

    var sourceType: SourceType {
        SourceType(rawValue: sourceTypeRawValue) ?? .file
    }

    var attachmentPaths: [String] {
        ModelPayload.decode([String].self, from: attachmentPathsPayload, fallback: [])
    }

    var selectedType: RecordType? {
        selectedTypeRawValue.flatMap(RecordType.init(rawValue:))
    }

    var machineExtraction: ExtractionResult? {
        ModelPayload.decodeOptional(ExtractionResult.self, from: machineExtractionPayload)
    }

    func bind(to batch: ImportBatch) throws {
        guard patientId == batch.patientId else { throw CaptureGroupingError.wrongPatient }
        guard batchId == batch.id else { throw CaptureGroupingError.wrongBatch }
        guard self.batch == nil || self.batch === batch else { throw CaptureGroupingError.wrongBatch }
        self.batch = batch
    }

    func bindPage(_ page: CapturePage) throws {
        try page.bind(to: self)
        guard !pages.contains(where: { $0.id == page.id }) else { return }
        pages.append(page)
        try reorderPages(pages.sorted {
            ($0.sourceOrder, $0.id.uuidString) < ($1.sourceOrder, $1.id.uuidString)
        })
    }

    func reorderPages(_ orderedPages: [CapturePage]) throws {
        guard Set(orderedPages.map(\.id)).count == orderedPages.count else {
            throw CaptureGroupingError.duplicatePageIndex
        }
        for (index, page) in orderedPages.enumerated() {
            try page.bind(to: self)
            page.setPageIndex(index)
        }
        pages = orderedPages
        groupingRevision += 1
        generation += 1
        updatedAt = Date()
    }
}

@Model
final class CapturePage {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var batchId: UUID
    private(set) var draftId: UUID
    private(set) var sourceOrder: Int
    private(set) var pageIndex: Int
    private(set) var stagingRelativePath: String?
    private(set) var attachmentId: UUID?
    private(set) var ocrGeneration: Int
    private(set) var ocrStatusRawValue: String
    private(set) var ocrTextPayload: Data
    private(set) var detectedNameCandidatesPayload: Data
    private(set) var hospitalSuggestion: String?
    private(set) var dateSuggestion: Date?
    private(set) var titleSuggestion: String?
    private(set) var pageMarker: String?
    private(set) var overlapFingerprint: String?
    private(set) var confirmedHospital: String?
    private(set) var confirmedDate: Date?
    private(set) var confirmedTitle: String?
    private(set) var createdAt: Date
    private(set) var contentRevision: Int
    private(set) var draft: CaptureDraft?

    init(
        id: UUID = UUID(),
        patientId: UUID,
        batchId: UUID,
        draftId: UUID,
        sourceOrder: Int,
        pageIndex: Int,
        stagingRelativePath: String? = nil,
        attachmentId: UUID? = nil,
        ocrGeneration: Int = 0,
        ocrStatus: CaptureOCRStatus = .pending,
        ocrText: String? = nil,
        detectedNameCandidates: [DetectedNameCandidate] = [],
        hospitalSuggestion: String? = nil,
        dateSuggestion: Date? = nil,
        titleSuggestion: String? = nil,
        pageMarker: String? = nil,
        overlapFingerprint: String? = nil,
        confirmedHospital: String? = nil,
        confirmedDate: Date? = nil,
        confirmedTitle: String? = nil,
        createdAt: Date = Date(),
        draft: CaptureDraft? = nil
    ) {
        precondition(sourceOrder >= 0 && pageIndex >= 0, "Capture page order must be non-negative")
        precondition(
            stagingRelativePath != nil || attachmentId != nil,
            "Capture page requires staging path or attachment"
        )
        self.id = id
        self.patientId = patientId
        self.batchId = batchId
        self.draftId = draftId
        self.sourceOrder = sourceOrder
        self.pageIndex = pageIndex
        self.stagingRelativePath = stagingRelativePath
        self.attachmentId = attachmentId
        self.ocrGeneration = max(0, ocrGeneration)
        self.ocrStatusRawValue = ocrStatus.rawValue
        self.ocrTextPayload = ModelPayload.requiredEncodeOptional(ocrText)
        self.detectedNameCandidatesPayload = ModelPayload.requiredEncode(detectedNameCandidates)
        self.hospitalSuggestion = MemberIdentity.optionalTrimmed(hospitalSuggestion)
        self.dateSuggestion = dateSuggestion
        self.titleSuggestion = MemberIdentity.optionalTrimmed(titleSuggestion)
        self.pageMarker = MemberIdentity.optionalTrimmed(pageMarker)
        self.overlapFingerprint = MemberIdentity.optionalTrimmed(overlapFingerprint)
        self.confirmedHospital = MemberIdentity.optionalTrimmed(confirmedHospital)
        self.confirmedDate = confirmedDate
        self.confirmedTitle = MemberIdentity.optionalTrimmed(confirmedTitle)
        self.createdAt = createdAt
        self.contentRevision = 0
        self.draft = draft
    }

    var ocrStatus: CaptureOCRStatus {
        CaptureOCRStatus(rawValue: ocrStatusRawValue) ?? .failed
    }

    var ocrText: String? {
        ModelPayload.decodeOptional(String.self, from: ocrTextPayload)
    }

    var detectedNameCandidates: [DetectedNameCandidate] {
        ModelPayload.decode(
            [DetectedNameCandidate].self,
            from: detectedNameCandidatesPayload,
            fallback: []
        )
    }

    func bind(to draft: CaptureDraft) throws {
        guard patientId == draft.patientId else { throw CaptureGroupingError.wrongPatient }
        guard batchId == draft.batchId else { throw CaptureGroupingError.wrongBatch }
        guard draftId == draft.id else { throw CaptureGroupingError.wrongDocument }
        guard self.draft == nil || self.draft === draft else {
            throw CaptureGroupingError.wrongDocument
        }
        self.draft = draft
    }

    func applyOCR(
        generation: Int,
        status: CaptureOCRStatus,
        text: String?,
        detectedNameCandidates: [DetectedNameCandidate],
        hospitalSuggestion: String? = nil,
        dateSuggestion: Date? = nil,
        titleSuggestion: String? = nil,
        pageMarker: String? = nil,
        overlapFingerprint: String? = nil
    ) throws {
        guard let draft, generation == draft.generation else {
            throw CaptureGroupingError.generationMismatch
        }
        self.ocrGeneration = generation
        self.ocrStatusRawValue = status.rawValue
        self.ocrTextPayload = ModelPayload.requiredEncodeOptional(text)
        self.detectedNameCandidatesPayload = ModelPayload.requiredEncode(detectedNameCandidates)
        self.hospitalSuggestion = MemberIdentity.optionalTrimmed(hospitalSuggestion)
        self.dateSuggestion = dateSuggestion
        self.titleSuggestion = MemberIdentity.optionalTrimmed(titleSuggestion)
        self.pageMarker = MemberIdentity.optionalTrimmed(pageMarker)
        self.overlapFingerprint = MemberIdentity.optionalTrimmed(overlapFingerprint)
    }

    fileprivate func setPageIndex(_ pageIndex: Int) {
        self.pageIndex = pageIndex
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
@Model
final class RecordAssignmentAudit {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var capturedForPatientId: UUID
    private(set) var assignedPatientId: UUID?
    private(set) var draftId: UUID?
    private(set) var recordId: UUID?
    private(set) var detectedName: String?
    private(set) var normalizedDetectedName: String?
    private(set) var outcomeRawValue: String
    private(set) var decisionRawValue: String
    private(set) var overrideReason: String?
    private(set) var engineIdentifier: String
    private(set) var engineVersion: String?
    private(set) var createdAt: Date

    init(
        id: UUID = UUID(),
        capturedForPatientId: UUID,
        assignedPatientId: UUID?,
        draftId: UUID? = nil,
        recordId: UUID? = nil,
        detectedName: String?,
        outcome: RecordAssignmentOutcome,
        decision: AssignmentDecision,
        overrideReason: String? = nil,
        engineIdentifier: String,
        engineVersion: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.capturedForPatientId = capturedForPatientId
        self.assignedPatientId = assignedPatientId
        self.draftId = draftId
        self.recordId = recordId
        self.detectedName = MemberIdentity.optionalTrimmed(detectedName)
        self.normalizedDetectedName = MemberIdentity.normalizedOptional(detectedName)
        self.outcomeRawValue = outcome.rawValue
        self.decisionRawValue = decision.rawValue
        self.overrideReason = MemberIdentity.optionalTrimmed(overrideReason)
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
        self.createdAt = createdAt
    }

    var outcome: RecordAssignmentOutcome {
        RecordAssignmentOutcome(rawValue: outcomeRawValue) ?? .ambiguous
    }

    var decision: AssignmentDecision {
        AssignmentDecision(rawValue: decisionRawValue) ?? .rejected
    }
}

@Model
final class ReminderSchedule {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var kindRawValue: String
    private(set) var title: String
    private(set) var notes: String?
    private(set) var schedulePayload: Data
    private(set) var revision: Int
    private(set) var isEnabled: Bool
    private(set) var sourceRecordId: UUID?
    private(set) var sourceMedicationId: UUID?
    private(set) var sourceFollowUpId: UUID?
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    private(set) var contentRevision: Int

    init(
        id: UUID = UUID(),
        patientId: UUID,
        kind: ReminderKind,
        title: String,
        notes: String? = nil,
        schedule: ReminderRule,
        revision: Int = 1,
        isEnabled: Bool = true,
        sourceRecordId: UUID? = nil,
        sourceMedicationId: UUID? = nil,
        sourceFollowUpId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        try schedule.validate()
        self.id = id
        self.patientId = patientId
        self.kindRawValue = kind.rawValue
        self.title = title
        self.notes = notes
        self.schedulePayload = ModelPayload.requiredEncode(schedule)
        self.revision = max(1, revision)
        self.isEnabled = isEnabled
        self.sourceRecordId = sourceRecordId
        self.sourceMedicationId = sourceMedicationId
        self.sourceFollowUpId = sourceFollowUpId
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.contentRevision = 0
    }

    var kind: ReminderKind {
        ReminderKind(rawValue: kindRawValue) ?? .custom
    }

    var schedule: ReminderRule {
        ModelPayload.decode(
            ReminderRule.self,
            from: schedulePayload,
            fallback: ReminderRule(kind: .once, startAt: createdAt)
        )
    }

    func updateBusinessRule(
        kind: ReminderKind,
        title: String,
        notes: String?,
        schedule: ReminderRule,
        isEnabled: Bool,
        at date: Date = Date()
    ) throws {
        try schedule.validate()
        kindRawValue = kind.rawValue
        self.title = title
        self.notes = notes
        schedulePayload = ModelPayload.requiredEncode(schedule)
        self.isEnabled = isEnabled
        revision += 1
        updatedAt = date
    }
}

@Model
final class AppleReminderBinding {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var patientId: UUID
    private(set) var reminderId: UUID
    private(set) var destinationRawValue: String
    private(set) var localNotificationIdentifier: String?
    private(set) var calendarEventIdentifier: String?
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    init(
        id: UUID = UUID(),
        patientId: UUID,
        reminderId: UUID,
        destination: ReminderDestination,
        localNotificationIdentifier: String? = nil,
        calendarEventIdentifier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.patientId = patientId
        self.reminderId = reminderId
        self.destinationRawValue = destination.rawValue
        self.localNotificationIdentifier = localNotificationIdentifier
        self.calendarEventIdentifier = calendarEventIdentifier
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var destination: ReminderDestination {
        ReminderDestination(rawValue: destinationRawValue) ?? .localNotification
    }

    /// Adapter re-binding must not mutate `ReminderSchedule.revision`.
    func updateIdentifiers(
        localNotificationIdentifier: String?,
        calendarEventIdentifier: String?,
        at date: Date = Date()
    ) {
        self.localNotificationIdentifier = localNotificationIdentifier
        self.calendarEventIdentifier = calendarEventIdentifier
        self.updatedAt = date
    }
}

@Model
final class ContentRevision {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var entityKindRawValue: String
    private(set) var entityId: UUID
    private(set) var patientId: UUID
    private(set) var revision: Int
    private(set) var changedFieldKeysPayload: Data
    private(set) var beforeContentPayload: Data
    private(set) var afterContentPayload: Data
    private(set) var sourceRawValue: String
    private(set) var actorRawValue: String
    private(set) var createdAt: Date

    init(
        id: UUID = UUID(),
        entityKind: EditableEntityKind,
        entityId: UUID,
        patientId: UUID,
        revision: Int,
        changedFieldKeys: [String],
        beforeContentPayload: Data,
        afterContentPayload: Data,
        source: ContentRevisionSource,
        actor: ContentRevisionActor = .localUser,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.entityKindRawValue = entityKind.rawValue
        self.entityId = entityId
        self.patientId = patientId
        self.revision = revision
        self.changedFieldKeysPayload = ModelPayload.requiredEncode(
            Array(Set(changedFieldKeys)).sorted()
        )
        self.beforeContentPayload = beforeContentPayload
        self.afterContentPayload = afterContentPayload
        self.sourceRawValue = source.rawValue
        self.actorRawValue = actor.rawValue
        self.createdAt = createdAt
    }

    var entityKind: EditableEntityKind {
        EditableEntityKind(rawValue: entityKindRawValue) ?? .medicalRecord
    }

    var changedFieldKeys: [String] {
        ModelPayload.decode([String].self, from: changedFieldKeysPayload, fallback: [])
    }

    var source: ContentRevisionSource {
        ContentRevisionSource(rawValue: sourceRawValue) ?? .manual
    }

    var actor: ContentRevisionActor {
        ContentRevisionActor(rawValue: actorRawValue) ?? .localUser
    }
}

}

protocol RevisionedEditable: PersistentModel {
    associatedtype EditableContent: Codable & Equatable

    static var editableEntityKind: EditableEntityKind { get }
    var editableEntityId: UUID { get }
    var editablePatientId: UUID { get }
    var contentRevision: Int { get }
    func editableContent() -> EditableContent
    func applyEditableContent(_ content: EditableContent) throws
    func bumpContentRevision()
    func restoreContentRevision(_ revision: Int)
}

extension Patient: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .patientProfile
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { id }

    func editableContent() -> PatientEditableContent {
        PatientEditableContent(
            displayName: displayName,
            reportName: reportName,
            aliases: aliases,
            birthDate: birthDate,
            gender: gender,
            conditions: conditions,
            allergies: allergies,
            histories: histories,
            careQuestions: careQuestions,
            updatedAt: updatedAt
        )
    }

    func applyEditableContent(_ content: PatientEditableContent) throws {
        try PatientProfilePolicy.validateIdentity(
            displayName: content.displayName,
            reportName: content.reportName,
            aliases: content.aliases,
            birthDate: content.birthDate,
            gender: content.gender
        )
        try PatientProfilePolicy.validateHealthLists(
            conditions: content.conditions,
            allergies: content.allergies,
            histories: content.histories
        )
        try PatientProfilePolicy.validateQuestions(content.careQuestions)
        updateIdentity(
            displayName: content.displayName,
            reportName: content.reportName,
            aliases: content.aliases
        )
        birthDate = content.birthDate
        gender = content.gender
        conditionsPayload = ModelPayload.requiredEncode(content.conditions)
        allergiesPayload = ModelPayload.requiredEncode(content.allergies)
        historiesPayload = ModelPayload.requiredEncode(content.histories)
        careQuestionsPayload = ModelPayload.requiredEncode(
            PatientProfilePolicy.normalizedQuestions(content.careQuestions)
        )
        updatedAt = content.updatedAt
    }

    func bumpContentRevision() {
        contentRevision += 1
        updatedAt = Date()
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
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

extension Medication: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .medication
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> MedicationEditableContent {
        MedicationEditableContent(
            name: name,
            doseValue: doseValue,
            doseUnit: doseUnit,
            frequency: frequency,
            weeklyCount: weeklyCount,
            usageNotes: usageNotes,
            startDate: startDate,
            endDate: endDate,
            isLongTerm: isLongTerm,
            hospital: hospital,
            department: department,
            linkedDiagnosis: linkedDiagnosis,
            caution: caution,
            reminderEnabled: reminderEnabled,
            reminderTimes: reminderTimes,
            remainingQuantity: remainingQuantity,
            refillReminderAt: refillReminderAt,
            lifecycleStatus: lifecycleStatus,
            updatedAt: updatedAt
        )
    }

    func applyEditableContent(_ content: MedicationEditableContent) {
        name = content.name
        doseValue = content.doseValue
        doseUnit = content.doseUnit
        frequency = content.frequency
        weeklyCount = content.weeklyCount
        usageNotes = content.usageNotes
        startDate = content.startDate
        endDate = content.endDate
        isLongTerm = content.isLongTerm
        hospital = content.hospital
        department = content.department
        linkedDiagnosis = content.linkedDiagnosis
        caution = content.caution
        reminderEnabled = content.reminderEnabled
        reminderTimes = content.reminderTimes
        remainingQuantity = content.remainingQuantity
        refillReminderAt = content.refillReminderAt
        lifecycleStatusRawValue = content.lifecycleStatus.rawValue
        updatedAt = content.updatedAt
    }

    func bumpContentRevision() {
        contentRevision += 1
        updatedAt = Date()
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}

extension MedicalOrder: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .medicalOrder
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> MedicalOrderEditableContent {
        MedicalOrderEditableContent(
            content: content,
            isCompleted: isCompleted,
            updatedAt: updatedAt
        )
    }

    func applyEditableContent(_ content: MedicalOrderEditableContent) {
        self.content = content.content
        isCompleted = content.isCompleted
        updatedAt = content.updatedAt
    }

    func bumpContentRevision() {
        contentRevision += 1
        updatedAt = Date()
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}

extension FollowUp: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .followUp
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> FollowUpEditableContent {
        FollowUpEditableContent(
            plannedDate: plannedDate,
            items: items,
            reason: reason,
            bringRecordIds: bringRecordIds,
            compareRecordId: compareRecordId,
            status: status,
            completedAt: completedAt,
            resultRecordId: resultRecordId,
            reminderEnabled: reminderEnabled,
            updatedAt: updatedAt
        )
    }

    func applyEditableContent(_ content: FollowUpEditableContent) {
        plannedDate = content.plannedDate
        items = content.items
        reason = content.reason
        bringRecordIds = content.bringRecordIds
        compareRecordId = content.compareRecordId
        status = content.status
        completedAt = content.completedAt
        resultRecordId = content.resultRecordId
        reminderEnabled = content.reminderEnabled
        updatedAt = content.updatedAt
    }

    func bumpContentRevision() {
        contentRevision += 1
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

extension ReminderSchedule: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .reminder
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> ReminderEditableContent {
        ReminderEditableContent(
            kind: kind,
            title: title,
            notes: notes,
            schedule: schedule,
            isEnabled: isEnabled,
            businessRevision: revision,
            updatedAt: updatedAt
        )
    }

    func applyEditableContent(_ content: ReminderEditableContent) throws {
        try content.schedule.validate()
        kindRawValue = content.kind.rawValue
        title = content.title
        notes = content.notes
        schedulePayload = ModelPayload.requiredEncode(content.schedule)
        isEnabled = content.isEnabled
        revision = content.businessRevision
        updatedAt = content.updatedAt
    }

    func bumpContentRevision() {
        contentRevision += 1
        revision += 1
        updatedAt = Date()
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}

extension CaptureDraft: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .captureDraft
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> CaptureDraftEditableContent {
        CaptureDraftEditableContent(
            confirmedTitle: confirmedTitle,
            selectedType: selectedType,
            selectedDate: selectedDate,
            updatedAt: updatedAt
        )
    }

    func applyEditableContent(_ content: CaptureDraftEditableContent) {
        confirmedTitle = MemberIdentity.optionalTrimmed(content.confirmedTitle)
        selectedTypeRawValue = content.selectedType?.rawValue
        selectedDate = content.selectedDate
        updatedAt = content.updatedAt
    }

    func bumpContentRevision() {
        contentRevision += 1
        updatedAt = Date()
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}

extension CapturePage: RevisionedEditable {
    static let editableEntityKind: EditableEntityKind = .capturePage
    var editableEntityId: UUID { id }
    var editablePatientId: UUID { patientId }

    func editableContent() -> CapturePageEditableContent {
        CapturePageEditableContent(
            confirmedHospital: confirmedHospital,
            confirmedDate: confirmedDate,
            confirmedTitle: confirmedTitle
        )
    }

    func applyEditableContent(_ content: CapturePageEditableContent) {
        confirmedHospital = MemberIdentity.optionalTrimmed(content.confirmedHospital)
        confirmedDate = content.confirmedDate
        confirmedTitle = MemberIdentity.optionalTrimmed(content.confirmedTitle)
    }

    func bumpContentRevision() {
        contentRevision += 1
    }

    func restoreContentRevision(_ revision: Int) {
        contentRevision = revision
    }
}
