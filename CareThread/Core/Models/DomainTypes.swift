import Foundation

enum RecordType: String, Codable, CaseIterable {
    case imaging
    case lab
    case pathology
    case discharge
    case outpatient
    case prescription
    case other

    var displayName: String {
        switch self {
        case .imaging: "影像报告"
        case .lab: "检验报告"
        case .pathology: "病理报告"
        case .discharge: "出院小结"
        case .outpatient: "门诊病历"
        case .prescription: "处方/医嘱单"
        case .other: "其他"
        }
    }
}

enum SourceType: String, Codable, CaseIterable {
    case camera
    case photo
    case file
    case manual
    case fixture
}

enum ReviewStatus: String, Codable, CaseIterable {
    case pending
    case confirmed
    case needsInfo
}

enum AttachmentKind: String, Codable {
    case image
    case pdf
}

enum FrequencyPreset: String, Codable, CaseIterable {
    case dailyOne
    case dailyTwo
    case dailyThree
    case everyOtherDay
    case weekly
    case asNeeded
}

enum FrequencySchedulePolicyError: Error, Equatable {
    case invalidWeeklyCount
    case unexpectedWeeklyCount
    case invalidReminderTime
    case duplicateReminderTime
    case reminderTimeCount(expected: Int, actual: Int)
    case asNeededCannotAutoSchedule
}

/// One source of truth for the semantic relationship between a medication
/// frequency and its local reminder clock values. Platform schedulers must not
/// reinterpret these presets.
enum FrequencySchedulePolicy {
    static func expectedReminderTimeCount(
        for frequency: FrequencyPreset
    ) -> Int {
        switch frequency {
        case .dailyOne, .everyOtherDay, .weekly:
            1
        case .dailyTwo:
            2
        case .dailyThree:
            3
        case .asNeeded:
            0
        }
    }

    static func validate(
        frequency: FrequencyPreset,
        weeklyCount: Int?,
        reminderEnabled: Bool,
        reminderTimes: [ReminderTime]
    ) throws {
        if frequency == .weekly {
            guard let weeklyCount, (1...7).contains(weeklyCount) else {
                throw FrequencySchedulePolicyError.invalidWeeklyCount
            }
        } else if weeklyCount != nil {
            throw FrequencySchedulePolicyError.unexpectedWeeklyCount
        }
        guard reminderTimes.allSatisfy({
            (0...23).contains($0.hour) && (0...59).contains($0.minute)
        }) else {
            throw FrequencySchedulePolicyError.invalidReminderTime
        }
        guard Set(reminderTimes).count == reminderTimes.count else {
            throw FrequencySchedulePolicyError.duplicateReminderTime
        }
        if frequency == .asNeeded {
            guard reminderTimes.isEmpty, !reminderEnabled else {
                throw FrequencySchedulePolicyError.asNeededCannotAutoSchedule
            }
            return
        }
        let expected = expectedReminderTimeCount(for: frequency)
        if reminderEnabled || !reminderTimes.isEmpty {
            guard reminderTimes.count == expected else {
                throw FrequencySchedulePolicyError.reminderTimeCount(
                    expected: expected,
                    actual: reminderTimes.count
                )
            }
        }
    }
}

enum DomainFieldPolicy {
    static let shortTextMaximumUTF8Bytes = 256
    static let unitMaximumUTF8Bytes = 32
    static let noteMaximumUTF8Bytes = 2_048
    static let listItemMaximumUTF8Bytes = 512
    static let listMaximumCount = 64

    static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    static func isWithinUTF8Limit(
        _ value: String,
        maximum: Int
    ) -> Bool {
        value.utf8.count <= maximum
    }
}

enum FollowUpStatus: String, Codable {
    case pending
    case completed
}

enum MedicationLifecycleStatus: String, Codable, CaseIterable {
    case active
    case completed
    case discontinued
    case superseded
}

enum LabFlag: String, Codable {
    case none
    case low
    case high
    case positive
}

enum Confidence: String, Codable {
    case high
    case low
}

/// Platform-neutral outcome of assigning an imported document to a member.
///
/// The raw values are part of the backup/export contract. Do not rename them.
enum RecordAssignmentOutcome: String, Codable, CaseIterable {
    case match
    case noEvidence
    case mismatch
    case ambiguous
}

enum AssignmentDecision: String, Codable, CaseIterable {
    case acceptedMatch
    case acceptedWithoutNameEvidence
    case switchedMember
    case acceptedAfterNameRecognitionOverride
    case rejected
}

enum EventDatePrecision: String, Codable, CaseIterable {
    case exactTime
    case day
    case month
    case year
    case unknown
}

enum RecordTagKind: String, Codable, CaseIterable {
    case disease
    case symptom
    case procedure
    case custom
}

enum AttachmentIntegrityState: String, Codable, CaseIterable {
    case pending
    case verified
    case missing
    case corrupted
}

enum ImportSource: String, Codable, CaseIterable {
    case camera
    case photoLibrary
    case files
    case generated
    case fixture
}

enum ReminderKind: String, Codable, CaseIterable {
    case medication
    case followUp
    case custom
}

enum ReminderDestination: String, Codable, CaseIterable {
    case localNotification
    case systemCalendar
}

enum ReminderRuleKind: String, Codable, CaseIterable {
    case once
    case daily
    case weekly
    case intervalDays
}

enum ImportBatchStatus: String, Codable, CaseIterable {
    case staging
    case recognizing
    case readyForReview
    case partiallyCommitted
    case completed
    case failed
}

enum CaptureOCRStatus: String, Codable, CaseIterable {
    case pending
    case recognizing
    case recognized
    case noEvidence
    case failed
}

struct ImportBatchState: Equatable {
    var status: ImportBatchStatus
    var generation: Int
    var updatedAt: Date
}

struct DetectedNameCandidate: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// OCR confidence in the closed range 0...1.
    var confidence: Double
    var isReliable: Bool

    init(
        id: UUID = UUID(),
        name: String,
        confidence: Double,
        isReliable: Bool
    ) {
        self.id = id
        self.name = name
        self.confidence = min(max(confidence, 0), 1)
        self.isReliable = isReliable
    }
}

enum ReminderRuleValidationError: Error, Equatable {
    case invalidTimezone
    case incompleteClock
    case invalidClock
    case invalidWeekday
    case weeklyDaysRequired
    case intervalRequired
    case endBeforeStart
}

enum EditableEntityKind: String, Codable, CaseIterable {
    case patientProfile
    case medicalRecord
    case medication
    case medicalOrder
    case followUp
    case labMeasurement
    case recordTag
    case reminder
    case captureDraft
    case capturePage
}

enum ContentRevisionSource: String, Codable, CaseIterable {
    case manual
    case ocrConfirmation
    case undo
}

enum ContentRevisionActor: String, Codable, CaseIterable {
    case localUser
}

struct PatientEditableContent: Codable, Equatable {
    var displayName: String
    var reportName: String?
    var aliases: [String]
    var birthDate: Date?
    var gender: String?
    var conditions: [String]
    var allergies: [String]
    var histories: [HistoryItem]
    var careQuestions: [CareQuestion]
    var updatedAt: Date

    init(
        displayName: String,
        reportName: String?,
        aliases: [String],
        birthDate: Date?,
        gender: String?,
        conditions: [String],
        allergies: [String],
        histories: [HistoryItem],
        careQuestions: [CareQuestion] = [],
        updatedAt: Date
    ) {
        self.displayName = displayName
        self.reportName = reportName
        self.aliases = aliases
        self.birthDate = birthDate
        self.gender = gender
        self.conditions = conditions
        self.allergies = allergies
        self.histories = histories
        self.careQuestions = careQuestions
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case reportName
        case aliases
        case birthDate
        case gender
        case conditions
        case allergies
        case histories
        case careQuestions
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decode(String.self, forKey: .displayName)
        reportName = try values.decodeIfPresent(
            String.self,
            forKey: .reportName
        )
        aliases = try values.decode([String].self, forKey: .aliases)
        birthDate = try values.decodeIfPresent(Date.self, forKey: .birthDate)
        gender = try values.decodeIfPresent(String.self, forKey: .gender)
        conditions = try values.decode([String].self, forKey: .conditions)
        allergies = try values.decode([String].self, forKey: .allergies)
        histories = try values.decode([HistoryItem].self, forKey: .histories)
        // Revision, backup and nearby payloads created before questions were
        // introduced remain losslessly readable.
        careQuestions = try values.decodeIfPresent(
            [CareQuestion].self,
            forKey: .careQuestions
        ) ?? []
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

struct MedicalRecordEditableContent: Codable, Equatable {
    var type: RecordType
    var title: String
    var summary: String
    var eventDate: Date
    var eventDatePrecision: EventDatePrecision
    var eventTimezoneIdentifier: String
    var hospital: String?
    var department: String?
    var doctor: String?
    var primaryDisease: String?
    var ageAtEvent: Int?
    var abnormalFlags: [String]
    var structuredFields: [KeyValueItem]
    var reviewStatus: ReviewStatus
    var isKeyRecord: Bool
    var inBrief: Bool
    var confirmedRevision: Int
    var confirmedAt: Date?
    var updatedAt: Date
}

struct MedicationEditableContent: Codable, Equatable {
    var name: String
    var doseValue: Double?
    var doseUnit: String
    var frequency: FrequencyPreset
    var weeklyCount: Int?
    var usageNotes: [String]
    var startDate: Date
    /// Exclusive upper bound; nil means open-ended.
    var endDate: Date?
    var isLongTerm: Bool
    var hospital: String?
    var department: String?
    var linkedDiagnosis: String?
    var caution: String?
    var reminderEnabled: Bool
    var reminderTimes: [ReminderTime]
    var remainingQuantity: Double?
    var refillReminderAt: Date?
    var lifecycleStatus: MedicationLifecycleStatus
    var updatedAt: Date
}

struct MedicalOrderEditableContent: Codable, Equatable {
    var content: String
    var isCompleted: Bool
    var updatedAt: Date
}

struct FollowUpEditableContent: Codable, Equatable {
    var plannedDate: Date
    var items: [String]
    var reason: String?
    var bringRecordIds: [UUID]
    var compareRecordId: UUID?
    var status: FollowUpStatus
    var completedAt: Date?
    var resultRecordId: UUID?
    var reminderEnabled: Bool
    var updatedAt: Date
}

struct LabMeasurementEditableContent: Codable, Equatable {
    var displayName: String
    var numericValue: Double?
    var textualValue: String?
    var unit: String
    var referenceLow: Double?
    var referenceHigh: Double?
    var referenceText: String?
    var abnormalState: LabFlag
    var confidence: Confidence
    var eventDate: Date
}

struct RecordTagEditableContent: Codable, Equatable {
    var kind: RecordTagKind
    var displayValue: String
}

struct ReminderEditableContent: Codable, Equatable {
    var kind: ReminderKind
    var title: String
    var notes: String?
    var schedule: ReminderRule
    var isEnabled: Bool
    var businessRevision: Int
    var updatedAt: Date
}

struct CaptureDraftEditableContent: Codable, Equatable {
    var confirmedTitle: String?
    var selectedType: RecordType?
    var selectedDate: Date?
    var updatedAt: Date
}

struct CapturePageEditableContent: Codable, Equatable {
    var confirmedHospital: String?
    var confirmedDate: Date?
    var confirmedTitle: String?
}

/// Cross-platform business schedule. Apple notification/calendar identifiers
/// live on `AppleReminderBinding`, outside this semantic value.
struct ReminderRule: Codable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var kind: ReminderRuleKind
    var startAt: Date
    var timezoneIdentifier: String
    var hour: Int?
    var minute: Int?
    /// ISO weekday numbers, Monday = 1 ... Sunday = 7.
    var isoWeekdays: [Int]
    var intervalDays: Int?
    var endAt: Date?

    init(
        schemaVersion: Int = currentSchemaVersion,
        kind: ReminderRuleKind,
        startAt: Date,
        timezoneIdentifier: String = TimeZone.current.identifier,
        hour: Int? = nil,
        minute: Int? = nil,
        isoWeekdays: [Int] = [],
        intervalDays: Int? = nil,
        endAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.startAt = startAt
        self.timezoneIdentifier = timezoneIdentifier
        self.hour = hour
        self.minute = minute
        self.isoWeekdays = isoWeekdays
        self.intervalDays = intervalDays
        self.endAt = endAt
    }

    func validate() throws {
        guard TimeZone(identifier: timezoneIdentifier) != nil else {
            throw ReminderRuleValidationError.invalidTimezone
        }
        guard (hour == nil) == (minute == nil) else {
            throw ReminderRuleValidationError.incompleteClock
        }
        if let hour, let minute, !(0...23).contains(hour) || !(0...59).contains(minute) {
            throw ReminderRuleValidationError.invalidClock
        }
        guard isoWeekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw ReminderRuleValidationError.invalidWeekday
        }
        if kind == .weekly && Set(isoWeekdays).isEmpty {
            throw ReminderRuleValidationError.weeklyDaysRequired
        }
        if kind == .intervalDays && (intervalDays ?? 0) <= 0 {
            throw ReminderRuleValidationError.intervalRequired
        }
        if let endAt, endAt < startAt {
            throw ReminderRuleValidationError.endBeforeStart
        }
    }
}

struct HistoryItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var year: Int
    var text: String
}

struct KeyValueItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String
}

struct LabItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var value: Double
    var unit: String
    var refLow: Double?
    var refHigh: Double?
    var flag: LabFlag
    var confidence: Confidence = .high
}

struct MedicationHint: Codable, Hashable {
    var name: String
    var doseValue: Double?
    var doseUnit: String?
    var frequencyPerDay: Int?
    var usage: [String]
    var confidence: Confidence
}

struct FollowUpHint: Codable, Hashable {
    var plannedDate: Date?
    var offsetDays: Int?
    var items: [String]
    var rawText: String
    var confidence: Confidence
}

struct ExtractionResult: Codable, Hashable {
    var type: RecordType
    var typeConfidence: Confidence
    var eventDate: Date?
    var eventDateConfidence: Confidence
    var hospital: String?
    var department: String?
    var title: String
    var summary: String
    var labItems: [LabItem]
    var abnormalFlags: [String]
    var structuredFields: [KeyValueItem]
    var medicationHints: [MedicationHint]
    var followUpHints: [FollowUpHint]
    var engineIdentifier: String

    static let empty = ExtractionResult(
        type: .other,
        typeConfidence: .low,
        eventDate: nil,
        eventDateConfidence: .low,
        hospital: nil,
        department: nil,
        title: "",
        summary: "",
        labItems: [],
        abnormalFlags: [],
        structuredFields: [],
        medicationHints: [],
        followUpHints: [],
        engineIdentifier: "none"
    )
}

struct ReminderTime: Codable, Hashable {
    var hour: Int
    var minute: Int
}

struct MedicationDraft: Equatable {
    var patientId: UUID
    var name: String
    var doseValue: Double
    var doseUnit: String
    var frequency: FrequencyPreset
    var weeklyCount: Int?
    var usageNotes: [String]
    var startDate: Date
    var endDate: Date?
    var isLongTerm: Bool
    var hospital: String?
    var department: String?
    var linkedDiagnosis: String?
    var caution: String?
    var sourceRecordId: UUID?
    var reminderEnabled: Bool
    var reminderTimes: [ReminderTime]
    var remainingQuantity: Double?
    var refillReminderAt: Date?

    init(
        patientId: UUID,
        name: String,
        doseValue: Double,
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
        reminderEnabled: Bool = false,
        reminderTimes: [ReminderTime] = [],
        remainingQuantity: Double? = nil,
        refillReminderAt: Date? = nil
    ) {
        self.patientId = patientId
        self.name = name
        self.doseValue = doseValue
        self.doseUnit = doseUnit
        self.frequency = frequency
        self.weeklyCount = weeklyCount
        self.usageNotes = usageNotes
        self.startDate = startDate
        self.endDate = endDate
        self.isLongTerm = isLongTerm
        self.hospital = hospital
        self.department = department
        self.linkedDiagnosis = linkedDiagnosis
        self.caution = caution
        self.sourceRecordId = sourceRecordId
        self.reminderEnabled = reminderEnabled
        self.reminderTimes = reminderTimes
        self.remainingQuantity = remainingQuantity
        self.refillReminderAt = refillReminderAt
    }
}
