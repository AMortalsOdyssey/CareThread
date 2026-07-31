import Foundation
import SwiftData

extension CareThreadSchemaV1 {

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
