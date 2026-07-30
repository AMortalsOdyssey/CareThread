import Foundation
import SwiftData

@Model
final class Patient {
    @Attribute(.unique) var id: UUID
    var name: String
    var birthday: Date?
    var gender: String?
    var conditions: [String]
    var allergies: [String]
    var histories: [HistoryItem]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "我的档案",
        birthday: Date? = nil,
        gender: String? = nil,
        conditions: [String] = [],
        allergies: [String] = [],
        histories: [HistoryItem] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.birthday = birthday
        self.gender = gender
        self.conditions = conditions
        self.allergies = allergies
        self.histories = histories
        self.createdAt = createdAt
    }
}

@Model
final class MedicalRecord {
    @Attribute(.unique) var id: UUID
    var patientId: UUID
    var type: RecordType
    var title: String
    var summary: String
    var eventDate: Date
    var hospital: String?
    var department: String?
    var doctor: String?
    var ageAtEvent: Int?
    var sourceType: SourceType
    var ocrText: String?
    var machineExtraction: ExtractionResult?
    var labItems: [LabItem]
    var abnormalFlags: [String]
    var structuredFields: [KeyValueItem]
    var reviewStatus: ReviewStatus
    var isKeyRecord: Bool
    var inBrief: Bool
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Attachment.record)
    var attachments: [Attachment]

    init(
        id: UUID = UUID(),
        patientId: UUID,
        type: RecordType = .other,
        title: String,
        summary: String = "",
        eventDate: Date,
        hospital: String? = nil,
        department: String? = nil,
        doctor: String? = nil,
        ageAtEvent: Int? = nil,
        sourceType: SourceType = .manual,
        ocrText: String? = nil,
        machineExtraction: ExtractionResult? = nil,
        labItems: [LabItem] = [],
        abnormalFlags: [String] = [],
        structuredFields: [KeyValueItem] = [],
        reviewStatus: ReviewStatus = .pending,
        isKeyRecord: Bool = false,
        inBrief: Bool = false,
        createdAt: Date = Date(),
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.patientId = patientId
        self.type = type
        self.title = title
        self.summary = summary
        self.eventDate = eventDate
        self.hospital = hospital
        self.department = department
        self.doctor = doctor
        self.ageAtEvent = ageAtEvent
        self.sourceType = sourceType
        self.ocrText = ocrText
        self.machineExtraction = machineExtraction
        self.labItems = labItems
        self.abnormalFlags = abnormalFlags
        self.structuredFields = structuredFields
        self.reviewStatus = reviewStatus
        self.isKeyRecord = isKeyRecord
        self.inBrief = inBrief
        self.createdAt = createdAt
        self.attachments = attachments
    }
}

@Model
final class Attachment {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var originalFileName: String?
    var kind: AttachmentKind
    var pageIndex: Int
    var record: MedicalRecord?

    init(
        id: UUID = UUID(),
        fileName: String,
        originalFileName: String? = nil,
        kind: AttachmentKind,
        pageIndex: Int,
        record: MedicalRecord? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.kind = kind
        self.pageIndex = pageIndex
        self.record = record
    }
}

@Model
final class Medication {
    @Attribute(.unique) var id: UUID
    var patientId: UUID
    var name: String
    var doseValue: Double?
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
    var previousVersionId: UUID?
    var reminderEnabled: Bool
    var reminderTimes: [ReminderTime]

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
        reminderTimes: [ReminderTime] = []
    ) {
        self.id = id
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
        self.previousVersionId = previousVersionId
        self.reminderEnabled = reminderEnabled
        self.reminderTimes = reminderTimes
    }
}

@Model
final class MedicalOrder {
    @Attribute(.unique) var id: UUID
    var patientId: UUID
    var content: String
    var sourceRecordId: UUID?
    var generatedFollowUpId: UUID?
    var isCompleted: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        patientId: UUID,
        content: String,
        sourceRecordId: UUID? = nil,
        generatedFollowUpId: UUID? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.patientId = patientId
        self.content = content
        self.sourceRecordId = sourceRecordId
        self.generatedFollowUpId = generatedFollowUpId
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}

@Model
final class FollowUp {
    @Attribute(.unique) var id: UUID
    var patientId: UUID
    var plannedDate: Date
    var items: [String]
    var reason: String?
    var bringRecordIds: [UUID]
    var compareRecordId: UUID?
    var status: FollowUpStatus
    var completedAt: Date?
    var resultRecordId: UUID?
    var reminderEnabled: Bool

    init(
        id: UUID = UUID(),
        patientId: UUID,
        plannedDate: Date,
        items: [String],
        reason: String? = nil,
        bringRecordIds: [UUID] = [],
        compareRecordId: UUID? = nil,
        status: FollowUpStatus = .pending,
        completedAt: Date? = nil,
        resultRecordId: UUID? = nil,
        reminderEnabled: Bool = true
    ) {
        self.id = id
        self.patientId = patientId
        self.plannedDate = plannedDate
        self.items = items
        self.reason = reason
        self.bringRecordIds = bringRecordIds
        self.compareRecordId = compareRecordId
        self.status = status
        self.completedAt = completedAt
        self.resultRecordId = resultRecordId
        self.reminderEnabled = reminderEnabled
    }
}

@Model
final class CaptureDraft {
    @Attribute(.unique) var id: UUID
    var patientId: UUID
    var sourceType: SourceType
    var attachmentPaths: [String]
    var selectedType: RecordType?
    var selectedDate: Date?
    var ocrText: String?
    var machineExtraction: ExtractionResult?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        patientId: UUID,
        sourceType: SourceType,
        attachmentPaths: [String] = [],
        selectedType: RecordType? = nil,
        selectedDate: Date? = nil,
        ocrText: String? = nil,
        machineExtraction: ExtractionResult? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.patientId = patientId
        self.sourceType = sourceType
        self.attachmentPaths = attachmentPaths
        self.selectedType = selectedType
        self.selectedDate = selectedDate
        self.ocrText = ocrText
        self.machineExtraction = machineExtraction
        self.updatedAt = updatedAt
    }
}

