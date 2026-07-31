import Foundation
import SwiftData

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
