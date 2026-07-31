import Foundation
import SwiftData

extension CareThreadSchemaV1 {

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
