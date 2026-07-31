import Foundation
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

enum M3CaptureSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case camera
    case photos
    case files
    case manual
    case fixture

    var id: String { rawValue }

    var sourceType: SourceType {
        switch self {
        case .camera: .camera
        case .photos, .fixture: .photo
        case .files: .file
        case .manual: .manual
        }
    }

    var importSource: ImportSource {
        switch self {
        case .camera: .camera
        case .photos: .photoLibrary
        case .files: .files
        case .manual: .generated
        case .fixture: .fixture
        }
    }
}

struct M3CapturePageAsset: Identifiable, Hashable {
    let id: UUID
    var stagedAssetID: UUID?
    var batchID: UUID?
    var displayName: String
    var relativePath: String?
    var previewRelativePath: String?
    var kind: AttachmentKind
    var sourceSessionID: String
    var sourceOrder: Int
    var rotationQuarterTurns: Int
    var pdfPageIndex: Int?
    var ocrText: String?
    var detectedNames: [DetectedNameCandidate]
    var suggestedHospital: String?
    var suggestedDate: Date?
    var suggestedTitle: String?
    var machineExtraction: ExtractionResult?
    var isSuggestedContinuation: Bool
    /// Exact origin of this page. A batch can mix camera, photos and files.
    var captureSource: M3CaptureSource?
    /// Flow generation at which OCR reached a terminal state for this page.
    var recognitionGeneration: Int?
    var recognitionStatus: CaptureOCRStatus?

    init(
        id: UUID = UUID(),
        stagedAssetID: UUID? = nil,
        batchID: UUID? = nil,
        displayName: String,
        relativePath: String? = nil,
        previewRelativePath: String? = nil,
        kind: AttachmentKind = .image,
        sourceSessionID: String = UUID().uuidString,
        sourceOrder: Int,
        rotationQuarterTurns: Int = 0,
        pdfPageIndex: Int? = nil,
        ocrText: String? = nil,
        detectedNames: [DetectedNameCandidate] = [],
        suggestedHospital: String? = nil,
        suggestedDate: Date? = nil,
        suggestedTitle: String? = nil,
        machineExtraction: ExtractionResult? = nil,
        isSuggestedContinuation: Bool = false,
        captureSource: M3CaptureSource? = nil,
        recognitionGeneration: Int? = nil,
        recognitionStatus: CaptureOCRStatus? = nil
    ) {
        self.id = id
        self.stagedAssetID = stagedAssetID
        self.batchID = batchID
        self.displayName = displayName
        self.relativePath = relativePath
        self.previewRelativePath = previewRelativePath
        self.kind = kind
        self.sourceSessionID = sourceSessionID
        self.sourceOrder = sourceOrder
        self.rotationQuarterTurns = rotationQuarterTurns
        self.pdfPageIndex = pdfPageIndex
        self.ocrText = ocrText
        self.detectedNames = detectedNames
        self.suggestedHospital = suggestedHospital
        self.suggestedDate = suggestedDate
        self.suggestedTitle = suggestedTitle
        self.machineExtraction = machineExtraction
        self.isSuggestedContinuation = isSuggestedContinuation
        self.captureSource = captureSource
        self.recognitionGeneration = recognitionGeneration
        self.recognitionStatus = recognitionStatus
    }
}

enum M3CaptureReadinessError: Error, Equatable {
    case staleOrIncompleteRecognition
}

enum M3NameGatePresentationPolicy {
    static func canOfferMemberSwitch(for outcome: RecordAssignmentOutcome) -> Bool {
        outcome == .mismatch
    }
}

/// Versioned metadata stored in CapturePage.pageMarker until the persistent
/// schema gains dedicated provenance/orientation columns.
struct M3PersistedPageMetadata: Codable, Equatable {
    static let currentVersion = 1
    private static let prefix = "ct-m3-page:"

    var schemaVersion = currentVersion
    var captureSourceRawValue: String?
    var rotationQuarterTurns: Int
    var pdfPageIndex: Int?
    var flowGeneration: Int
    var recognitionGeneration: Int?
    var recognitionStatusRawValue: String?

    init(page: M3CapturePageAsset, flowGeneration: Int) {
        captureSourceRawValue = page.captureSource?.rawValue
        rotationQuarterTurns = ((page.rotationQuarterTurns % 4) + 4) % 4
        pdfPageIndex = page.pdfPageIndex
        self.flowGeneration = max(0, flowGeneration)
        recognitionGeneration = page.recognitionGeneration
        recognitionStatusRawValue = page.recognitionStatus?.rawValue
    }

    var captureSource: M3CaptureSource? {
        captureSourceRawValue.flatMap(M3CaptureSource.init(rawValue:))
    }

    var recognitionStatus: CaptureOCRStatus? {
        recognitionStatusRawValue.flatMap(CaptureOCRStatus.init(rawValue:))
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString()
    }

    static func decode(_ value: String?) -> M3PersistedPageMetadata? {
        guard let value, value.hasPrefix(prefix),
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let metadata = try? JSONDecoder().decode(Self.self, from: data),
              metadata.schemaVersion == currentVersion else {
            return nil
        }
        return metadata
    }
}

struct M3CaptureDocument: Identifiable, Hashable {
    let id: UUID
    var pages: [M3CapturePageAsset]

    init(id: UUID = UUID(), pages: [M3CapturePageAsset]) {
        self.id = id
        self.pages = pages
    }
}

struct M3ConfirmationDocument: Identifiable {
    let id: UUID
    let draftID: UUID?
    let generation: Int?
    let evidence: CaptureNameEvidence?
    let sourceType: SourceType
    let importSource: ImportSource
    let pages: [M3CapturePageAsset]
    let machine: ExtractionResult
    var type: RecordType
    var title: String
    var summary: String
    var eventDate: Date
    var hospital: String
    var department: String
    var doctor: String
    var diseases: String
    var structuredFields: [KeyValueItem]
    var labItems: [LabItem]
    /// User-facing abnormal labels are edited independently from the immutable
    /// machine extraction. An empty array is a valid confirmed value.
    var abnormalItems: [String] = []
    /// Text-backed editing preserves a blank numeric field as blank. `LabItem`
    /// itself requires a Double, so only complete, valid rows are materialized.
    var labDrafts: [M3LabItemDraft] = []
    /// Used only when the assigned member has no birthday.
    var manualAgeText: String = ""

    var diseaseValues: [String] {
        diseases
            .components(separatedBy: CharacterSet(charactersIn: "、,，;；"))
            .compactMap(MemberIdentity.optionalTrimmed)
    }
}

struct M3LabItemDraft: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var valueText: String
    var unit: String
    var refLowText: String
    var refHighText: String
    var flag: LabFlag
    var confidence: Confidence

    init(
        id: UUID = UUID(),
        name: String = "",
        valueText: String = "",
        unit: String = "",
        refLowText: String = "",
        refHighText: String = "",
        flag: LabFlag = .none,
        confidence: Confidence = .high
    ) {
        self.id = id
        self.name = name
        self.valueText = valueText
        self.unit = unit
        self.refLowText = refLowText
        self.refHighText = refHighText
        self.flag = flag
        self.confidence = confidence
    }

    init(item: LabItem) {
        id = item.id
        name = item.name
        valueText = Self.numberString(item.value)
        unit = item.unit
        refLowText = item.refLow.map(Self.numberString) ?? ""
        refHighText = item.refHigh.map(Self.numberString) ?? ""
        flag = item.flag
        confidence = item.confidence
    }

    var hasBlankValue: Bool {
        valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasInvalidNumber: Bool {
        guard !hasBlankValue else { return false }
        guard Self.number(valueText) != nil else { return true }
        if !refLowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Self.number(refLowText) == nil {
            return true
        }
        if !refHighText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Self.number(refHighText) == nil {
            return true
        }
        return false
    }

    var hasInvalidReferenceOrder: Bool {
        guard let low = Self.number(refLowText),
              let high = Self.number(refHighText) else {
            return false
        }
        return low > high
    }

    var hasValidationError: Bool {
        hasInvalidNumber || hasInvalidReferenceOrder
    }

    func materialized() -> LabItem? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let value = Self.number(valueText),
              !hasInvalidNumber else {
            return nil
        }
        let low = Self.number(refLowText)
        let high = Self.number(refHighText)
        guard !hasInvalidReferenceOrder else { return nil }
        return LabItem(
            id: id,
            name: trimmedName,
            value: value,
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
            refLow: low,
            refHigh: high,
            flag: flag,
            confidence: confidence
        )
    }

    private static func number(_ text: String) -> Double? {
        let value = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard !value.isEmpty,
              let number = Double(value),
              number.isFinite else {
            return nil
        }
        return number
    }

    private static func numberString(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...6)))
    }
}

enum M3ConfirmationPolicy {
    static func isFutureEventDate(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = CTDate.calendar
    ) -> Bool {
        calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
    }

    static func reviewStatus(
        title: String,
        eventDate: Date,
        now: Date = Date(),
        calendar: Calendar = CTDate.calendar
    ) -> ReviewStatus {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsInfo
        }
        if isFutureEventDate(eventDate, now: now, calendar: calendar) {
            return .pending
        }
        return .confirmed
    }

    static func manualAge(from text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let age = Int(value),
              (0...130).contains(age) else {
            return nil
        }
        return age
    }

    static func isManualAgeValid(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || manualAge(from: value) != nil
    }
}

@MainActor
final class M3CaptureFlowController: ObservableObject {
    enum Phase {
        case sources
        case workbench
        case processing
        case confirmation
        case completed
    }

    @Published var phase: Phase = .sources
    @Published var documents: [M3CaptureDocument] = []
    @Published var confirmations: [M3ConfirmationDocument] = []
    @Published var activeSource: M3CaptureSource?
    @Published var groupingConfirmed = false
    @Published var errorMessage: String?
    @Published var completedRecordCount = 0
    @Published var activePreviewPage: M3CapturePageAsset?
    @Published var processedPageCount = 0
    @Published var totalProcessingPageCount = 0
    @Published var hasCompletedRecognition = false
    @Published var hasAppliedGroupingSuggestions = false
    @Published private(set) var hasManualGroupingEdits = false
    @Published var duplicateSuggestionCount = 0
    @Published var largeDocumentWarningAcknowledged = false
    @Published private(set) var flowGeneration = 0

    let frozenPatientID: UUID
    let frozenPatientName: String
    let frozenReportNames: [String]
    let frozenPatientBirthDate: Date?
    var activeBatchID: UUID?

    init(patient: Patient) {
        frozenPatientID = patient.id
        frozenPatientName = patient.displayName
        frozenReportNames = [patient.reportName].compactMap { $0 } + patient.aliases
#if DEBUG
        frozenPatientBirthDate = ProcessInfo.processInfo.arguments.contains(
            "-M3MissingBirthdayConfirmation"
        ) ? nil : patient.birthDate
#else
        frozenPatientBirthDate = patient.birthDate
#endif
    }

    var pageCount: Int {
        documents.reduce(0) { $0 + $1.pages.count }
    }

    var requiresLargeDocumentAcknowledgement: Bool {
        documents.contains { $0.pages.count > 20 }
            && !largeDocumentWarningAcknowledged
    }

    func beginManual() {
        activeSource = .manual
        let machine = ExtractionResult.empty
        let eventDate: Date
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-M3FutureDateConfirmation") {
            eventDate = CTDate.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        } else {
            eventDate = Date()
        }
#else
        eventDate = Date()
#endif
        confirmations = [
            M3ConfirmationDocument(
                id: UUID(),
                draftID: nil,
                generation: nil,
                evidence: nil,
                sourceType: .manual,
                importSource: .generated,
                pages: [],
                machine: machine,
                type: .other,
                title: "",
                summary: "",
                eventDate: eventDate,
                hospital: "",
                department: "",
                doctor: "",
                diseases: "",
                structuredFields: [],
                labItems: []
            )
        ]
        phase = .confirmation
    }

    func loadFixture(mismatch: Bool, ambiguous: Bool = false) {
        activeSource = .fixture
        let firstName = mismatch ? "陈小雨" : frozenReportNames.first
        let conflictingName = ambiguous ? "李明" : nil
        let date = CTDate.make(2026, 7, 18)
        documents = [
            M3CaptureDocument(
                pages: [
                    M3CapturePageAsset(
                        displayName: Copy.Capture.fixtureLabPage(1),
                        sourceOrder: 0,
                        ocrText: [
                            firstName.map { "姓名：\($0)" },
                            "虚构市中心医院",
                            "血常规检验报告",
                            "白细胞 6.2 ×10⁹/L"
                        ].compactMap { $0 }.joined(separator: "\n"),
                        detectedNames: firstName.map {
                            [
                                DetectedNameCandidate(
                                    name: $0,
                                    confidence: 0.96,
                                    isReliable: true
                                )
                            ]
                        } ?? [],
                        suggestedHospital: "虚构市中心医院",
                        suggestedDate: date,
                        suggestedTitle: "血常规检验报告",
                        captureSource: .fixture
                    ),
                    M3CapturePageAsset(
                        displayName: Copy.Capture.fixtureLabPage(2),
                        sourceOrder: 1,
                        ocrText: [
                            conflictingName.map { "姓名：\($0)" },
                            "血红蛋白 132 g/L",
                            "血小板 225 ×10⁹/L"
                        ].compactMap { $0 }.joined(separator: "\n"),
                        detectedNames: conflictingName.map {
                            [
                                DetectedNameCandidate(
                                    name: $0,
                                    confidence: 0.98,
                                    isReliable: true
                                )
                            ]
                        } ?? [],
                        suggestedHospital: "虚构市中心医院",
                        suggestedDate: date,
                        suggestedTitle: "血常规检验报告",
                        isSuggestedContinuation: true,
                        captureSource: .fixture
                    ),
                    M3CapturePageAsset(
                        displayName: Copy.Capture.fixtureImagingPage(1),
                        sourceOrder: 2,
                        ocrText: [
                            frozenReportNames.first.map { "姓名：\($0)" },
                            "虚构市中心医院",
                            "腹部超声检查报告"
                        ].compactMap { $0 }.joined(separator: "\n"),
                        detectedNames: frozenReportNames.first.map {
                            [
                                DetectedNameCandidate(
                                    name: $0,
                                    confidence: 0.97,
                                    isReliable: true
                                )
                            ]
                        } ?? [],
                        suggestedHospital: "虚构市中心医院",
                        suggestedDate: date,
                        suggestedTitle: "腹部超声检查报告",
                        captureSource: .fixture
                    ),
                    M3CapturePageAsset(
                        displayName: Copy.Capture.fixtureImagingPage(2),
                        sourceOrder: 3,
                        ocrText: "检查所见：肝胆胰脾未见明显异常。\n本页无个人信息。",
                        suggestedHospital: "虚构市中心医院",
                        suggestedDate: date,
                        suggestedTitle: "腹部超声检查报告",
                        isSuggestedContinuation: true,
                        captureSource: .fixture
                    )
                ]
            )
        ]
        groupingConfirmed = false
        hasManualGroupingEdits = false
        largeDocumentWarningAcknowledged = false
        invalidateRecognitionAndGrouping()
        phase = .workbench
    }

#if DEBUG
    /// Deterministic zero-text OCR terminal state for B5 UI semantics. The
    /// host still materializes a real draft and saves through CaptureCommitService.
    func loadBlankOCRConfirmationFixtureState(page: M3CapturePageAsset) {
        activeSource = .fixture
        documents = [
            M3CaptureDocument(
                pages: [page]
            )
        ]
        groupingConfirmed = true
        hasManualGroupingEdits = false
        largeDocumentWarningAcknowledged = false
        hasCompletedRecognition = true
        hasAppliedGroupingSuggestions = true
        phase = .processing
    }

    /// Deterministic UI fixture for the ambiguity gate. Pipeline behavior is
    /// covered separately; this fixture isolates the available user actions.
    func loadAmbiguousConfirmationFixture() {
        loadFixture(mismatch: false, ambiguous: true)
        guard let document = documents.first else { return }
        confirmations = [
            M3ConfirmationDocument(
                id: document.id,
                draftID: nil,
                generation: nil,
                evidence: CaptureNameEvidence(
                    outcome: .ambiguous,
                    detectedName: "\(frozenPatientName)、李明",
                    reliableNormalizedNames: [
                        MemberIdentity.normalize(frozenPatientName),
                        MemberIdentity.normalize("李明")
                    ]
                ),
                sourceType: .photo,
                importSource: .fixture,
                pages: document.pages,
                machine: .empty,
                type: .other,
                title: "虚构多姓名报告",
                summary: "",
                eventDate: CTDate.make(2026, 7, 18),
                hospital: "虚构市中心医院",
                department: "",
                doctor: "",
                diseases: "",
                structuredFields: [],
                labItems: []
            )
        ]
        phase = .confirmation
    }
#endif

    func loadAssets(_ assets: [M3CapturePageAsset], source: M3CaptureSource) {
        guard !assets.isEmpty else { return }
        guard pageCount + assets.count <= 100 else {
            errorMessage = Copy.Capture.pageLimit
            return
        }
        activeSource = source
        documents = [
            M3CaptureDocument(
                pages: assets.map { asset in
                    var value = asset
                    value.captureSource = value.captureSource ?? source
                    return value
                }
            )
        ]
        groupingConfirmed = false
        hasManualGroupingEdits = false
        largeDocumentWarningAcknowledged = false
        invalidateRecognitionAndGrouping()
        phase = .workbench
    }

    func appendAssets(_ assets: [M3CapturePageAsset]) {
        guard !assets.isEmpty else { return }
        guard pageCount + assets.count <= 100 else {
            errorMessage = Copy.Capture.pageLimit
            return
        }
        let scopedAssets = assets.map { asset in
            var value = asset
            value.captureSource = value.captureSource ?? activeSource
            return value
        }
        if documents.isEmpty {
            documents = [M3CaptureDocument(pages: scopedAssets)]
        } else {
            documents[documents.count - 1].pages.append(contentsOf: scopedAssets)
        }
        normalizeOrders()
        groupingConfirmed = false
        hasManualGroupingEdits = false
        largeDocumentWarningAcknowledged = false
        invalidateRecognitionAndGrouping()
    }

    func split(documentIndex: Int, beforePageIndex: Int) {
        guard documents.indices.contains(documentIndex),
              beforePageIndex > 0,
              beforePageIndex < documents[documentIndex].pages.count else { return }
        let headPDFs = Set(
            documents[documentIndex].pages[..<beforePageIndex]
                .filter { $0.kind == .pdf }
                .compactMap(\.stagedAssetID)
        )
        let tailPDFs = Set(
            documents[documentIndex].pages[beforePageIndex...]
                .filter { $0.kind == .pdf }
                .compactMap(\.stagedAssetID)
        )
        if !headPDFs.isDisjoint(with: tailPDFs) {
            errorMessage = Copy.Capture.pdfBoundaryLocked
            return
        }
        let tail = Array(documents[documentIndex].pages[beforePageIndex...])
        documents[documentIndex].pages.removeSubrange(beforePageIndex...)
        documents.insert(M3CaptureDocument(pages: tail), at: documentIndex + 1)
        normalizeOrders()
        groupingConfirmed = false
        hasManualGroupingEdits = true
        largeDocumentWarningAcknowledged = false
    }

    func mergeWithPrevious(documentIndex: Int) {
        guard documentIndex > 0, documents.indices.contains(documentIndex) else { return }
        let moving = documents.remove(at: documentIndex)
        guard documents[documentIndex - 1].pages.count + moving.pages.count <= 50 else {
            documents.insert(moving, at: documentIndex)
            errorMessage = Copy.Capture.pageLimit
            return
        }
        documents[documentIndex - 1].pages.append(contentsOf: moving.pages)
        normalizeOrders()
        groupingConfirmed = false
        hasManualGroupingEdits = true
        largeDocumentWarningAcknowledged = false
    }

    func movePage(documentIndex: Int, pageIndex: Int, offset: Int) {
        guard documents.indices.contains(documentIndex),
              documents[documentIndex].pages.indices.contains(pageIndex) else { return }
        let target = pageIndex + offset
        guard documents[documentIndex].pages.indices.contains(target) else { return }
        documents[documentIndex].pages.swapAt(pageIndex, target)
        normalizeOrders()
        groupingConfirmed = false
        hasManualGroupingEdits = true
    }

    func rotate(documentIndex: Int, pageIndex: Int) {
        guard documents.indices.contains(documentIndex),
              documents[documentIndex].pages.indices.contains(pageIndex) else { return }
        documents[documentIndex].pages[pageIndex].rotationQuarterTurns =
            (documents[documentIndex].pages[pageIndex].rotationQuarterTurns + 1) % 4
        groupingConfirmed = false
        invalidateRecognitionAndGrouping()
    }

    func deletePage(documentIndex: Int, pageIndex: Int) {
        guard documents.indices.contains(documentIndex),
              documents[documentIndex].pages.indices.contains(pageIndex) else { return }
        documents[documentIndex].pages.remove(at: pageIndex)
        if documents[documentIndex].pages.isEmpty {
            documents.remove(at: documentIndex)
        }
        normalizeOrders()
        groupingConfirmed = false
        hasManualGroupingEdits = true
        largeDocumentWarningAcknowledged = false
    }

    func markGroupingConfirmed() {
        guard !requiresLargeDocumentAcknowledgement else {
            errorMessage = Copy.Capture.largeDocumentWarning
            groupingConfirmed = false
            return
        }
        var documentByPDFAsset: [UUID: UUID] = [:]
        for document in documents {
            for assetID in Set(
                document.pages
                    .filter { $0.kind == .pdf }
                    .compactMap(\.stagedAssetID)
            ) {
                if let existing = documentByPDFAsset[assetID],
                   existing != document.id {
                    errorMessage = Copy.Capture.pdfBoundaryLocked
                    groupingConfirmed = false
                    return
                }
                documentByPDFAsset[assetID] = document.id
            }
        }
        groupingConfirmed = !documents.isEmpty
    }

    func acknowledgeLargeDocument() {
        largeDocumentWarningAcknowledged = true
        errorMessage = nil
        groupingConfirmed = false
    }

    func normalizeOrders() {
        var order = 0
        for documentIndex in documents.indices {
            for pageIndex in documents[documentIndex].pages.indices {
                documents[documentIndex].pages[pageIndex].sourceOrder = order
                order += 1
            }
        }
    }

    func markRecognitionCompleted() {
        for document in documents {
            for page in document.pages where page.captureSource != .fixture {
                guard let status = page.recognitionStatus,
                      page.recognitionGeneration == flowGeneration,
                      [.recognized, .noEvidence].contains(status) else {
                    hasCompletedRecognition = false
                    return
                }
            }
        }
        hasCompletedRecognition = true
    }

    func validateReadyForMaterialization() throws {
        for document in documents {
            for page in document.pages where page.captureSource != .fixture {
                guard let status = page.recognitionStatus,
                      page.recognitionGeneration == flowGeneration,
                      [.recognized, .noEvidence].contains(status) else {
                    throw M3CaptureReadinessError.staleOrIncompleteRecognition
                }
            }
        }
    }

    func restoreRecognitionState(flowGeneration: Int) {
        self.flowGeneration = max(0, flowGeneration)
        markRecognitionCompleted()
        hasAppliedGroupingSuggestions = false
    }

    private func invalidateRecognitionAndGrouping() {
        flowGeneration += 1
        for documentIndex in documents.indices {
            for pageIndex in documents[documentIndex].pages.indices {
                documents[documentIndex].pages[pageIndex].recognitionGeneration = nil
                documents[documentIndex].pages[pageIndex].recognitionStatus = nil
            }
        }
        hasCompletedRecognition = false
        hasAppliedGroupingSuggestions = false
        duplicateSuggestionCount = 0
    }
}

enum M3CaptureFileStore {
    static func storeData(
        _ data: Data,
        fileExtension: String,
        batchID: UUID,
        sourceOrder: Int,
        displayName: String,
        captureSource: M3CaptureSource
    ) throws -> M3CapturePageAsset {
        let staged = try CaptureVaultService().stagePhotoData(
            data,
            batchID: batchID,
            displayName: displayName,
            preferredExtension: fileExtension
        )
        return M3CapturePageAsset(
            stagedAssetID: staged.id,
            batchID: batchID,
            displayName: displayName,
            relativePath: staged.originalRelativePath,
            previewRelativePath: staged.previewRelativePath,
            kind: staged.kind,
            sourceSessionID: staged.id.uuidString,
            sourceOrder: sourceOrder,
            captureSource: captureSource
        )
    }

    static func assets(
        fromFile url: URL,
        batchID: UUID,
        startingAt sourceOrder: Int
    ) throws -> [M3CapturePageAsset] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let staged = try CaptureVaultService().stageFile(
            at: url,
            batchID: batchID
        )
        if staged.kind == .pdf {
            let count = max(staged.pageCount ?? 1, 1)
            return (0..<count).map { pageIndex in
                M3CapturePageAsset(
                    stagedAssetID: staged.id,
                    batchID: batchID,
                    displayName: Copy.Capture.importedFilePage(
                        staged.displayName,
                        pageIndex + 1
                    ),
                    relativePath: staged.originalRelativePath,
                    previewRelativePath: staged.previewRelativePath,
                    kind: .pdf,
                    sourceSessionID: staged.id.uuidString,
                    sourceOrder: sourceOrder + pageIndex,
                    pdfPageIndex: pageIndex,
                    isSuggestedContinuation: pageIndex > 0,
                    captureSource: .files
                )
            }
        }
        return [
            M3CapturePageAsset(
                stagedAssetID: staged.id,
                batchID: batchID,
                displayName: staged.displayName,
                relativePath: staged.originalRelativePath,
                previewRelativePath: staged.previewRelativePath,
                kind: .image,
                sourceSessionID: staged.id.uuidString,
                sourceOrder: sourceOrder,
                pdfPageIndex: nil,
                captureSource: .files
            )
        ]
    }

    static func asset(
        fromImageData data: Data,
        batchID: UUID,
        sourceOrder: Int,
        displayName: String,
        captureSource: M3CaptureSource
    ) throws
        -> M3CapturePageAsset {
        try storeData(
            data,
            fileExtension: "jpg",
            batchID: batchID,
            sourceOrder: sourceOrder,
            displayName: displayName,
            captureSource: captureSource
        )
    }
}
