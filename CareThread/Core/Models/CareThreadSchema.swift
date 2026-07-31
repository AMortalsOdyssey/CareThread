import SwiftData

enum CareThreadSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            CareThreadSchemaV1.Patient.self,
            CareThreadSchemaV1.MedicalRecord.self,
            CareThreadSchemaV1.Attachment.self,
            CareThreadSchemaV1.Medication.self,
            CareThreadSchemaV1.MedicalOrder.self,
            CareThreadSchemaV1.FollowUp.self,
            CareThreadSchemaV1.ImportBatch.self,
            CareThreadSchemaV1.CaptureDraft.self,
            CareThreadSchemaV1.CapturePage.self,
            CareThreadSchemaV1.LabMeasurement.self,
            CareThreadSchemaV1.RecordTag.self,
            CareThreadSchemaV1.RecordAssignmentAudit.self,
            CareThreadSchemaV1.ReminderSchedule.self,
            CareThreadSchemaV1.AppleReminderBinding.self,
            CareThreadSchemaV1.ContentRevision.self
        ]
    }
}

typealias Patient = CareThreadSchemaV1.Patient
typealias MedicalRecord = CareThreadSchemaV1.MedicalRecord
typealias Attachment = CareThreadSchemaV1.Attachment
typealias Medication = CareThreadSchemaV1.Medication
typealias MedicalOrder = CareThreadSchemaV1.MedicalOrder
typealias FollowUp = CareThreadSchemaV1.FollowUp
typealias ImportBatch = CareThreadSchemaV1.ImportBatch
typealias CaptureDraft = CareThreadSchemaV1.CaptureDraft
typealias CapturePage = CareThreadSchemaV1.CapturePage
typealias LabMeasurement = CareThreadSchemaV1.LabMeasurement
typealias RecordTag = CareThreadSchemaV1.RecordTag
typealias RecordAssignmentAudit = CareThreadSchemaV1.RecordAssignmentAudit
typealias ReminderSchedule = CareThreadSchemaV1.ReminderSchedule
typealias AppleReminderBinding = CareThreadSchemaV1.AppleReminderBinding
typealias ContentRevision = CareThreadSchemaV1.ContentRevision

enum CareThreadMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [CareThreadSchemaV1.self]
    }

    /// V1 is the first unpublished on-device schema. Optional rebuildable
    /// derived fields may evolve in place until the first public release; V1
    /// freezes at that release and every later shape change requires a new
    /// version plus an explicit migration stage.
    static var stages: [MigrationStage] {
        []
    }
}
