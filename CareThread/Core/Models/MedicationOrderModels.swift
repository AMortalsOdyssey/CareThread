import Foundation
import SwiftData

extension CareThreadSchemaV1 {

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
