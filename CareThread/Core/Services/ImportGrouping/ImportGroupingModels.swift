import Foundation

/// The original acquisition path. Only sources that intrinsically contain ordered pages
/// are allowed to contribute a strong "same document" signal.
enum ImportPageSource: String, Codable, CaseIterable, Sendable {
    case photoSelection
    case cameraCapture
    case multiPagePDF
    case visionKitScan
}

struct ImportNameEvidence: Hashable, Codable, Sendable {
    let value: String
    let confidence: Double

    init(value: String, confidence: Double) {
        self.value = value
        self.confidence = confidence
    }
}

/// In-memory domain evidence produced by local OCR and acquisition metadata.
/// It deliberately contains no SwiftData or UIKit types. Its synthesized `Codable`
/// representation is not a cross-device or cross-platform wire contract: an adapter
/// must version its schema and encode `Date` values explicitly before transport.
struct ImportPageEvidence: Hashable, Codable, Sendable {
    let pageID: UUID
    let sourceOrder: Int
    let sourceSessionID: String
    let source: ImportPageSource
    let names: [ImportNameEvidence]
    let hospital: String?
    let eventDate: Date?
    let capturedAt: Date?
    let reportTitle: String?
    let reportNumber: String?
    let pageNumber: Int?
    let totalPages: Int?
    let topOCRLines: [String]
    let bottomOCRLines: [String]
    let firstPageStructureScore: Double

    init(
        pageID: UUID,
        sourceOrder: Int,
        sourceSessionID: String,
        source: ImportPageSource,
        names: [ImportNameEvidence] = [],
        hospital: String? = nil,
        eventDate: Date? = nil,
        capturedAt: Date? = nil,
        reportTitle: String? = nil,
        reportNumber: String? = nil,
        pageNumber: Int? = nil,
        totalPages: Int? = nil,
        topOCRLines: [String] = [],
        bottomOCRLines: [String] = [],
        firstPageStructureScore: Double = 0
    ) {
        self.pageID = pageID
        self.sourceOrder = sourceOrder
        self.sourceSessionID = sourceSessionID
        self.source = source
        self.names = names
        self.hospital = hospital
        self.eventDate = eventDate
        self.capturedAt = capturedAt
        self.reportTitle = reportTitle
        self.reportNumber = reportNumber
        self.pageNumber = pageNumber
        self.totalPages = totalPages
        self.topOCRLines = topOCRLines
        self.bottomOCRLines = bottomOCRLines
        self.firstPageStructureScore = firstPageStructureScore
    }
}

enum ImportBoundaryDecision: String, Codable, Sendable {
    case sameDocument
    case newDocument
    case uncertain
}

enum ImportBoundaryOverrideDecision: String, Codable, Sendable {
    case sameDocument
    case newDocument
}

struct ImportBoundaryKey: Hashable, Codable, Sendable {
    let previousPageID: UUID
    let nextPageID: UUID

    init(previousPageID: UUID, nextPageID: UUID) {
        self.previousPageID = previousPageID
        self.nextPageID = nextPageID
    }
}

struct ImportBoundaryOverride: Hashable, Codable, Sendable {
    let key: ImportBoundaryKey
    let decision: ImportBoundaryOverrideDecision

    init(
        previousPageID: UUID,
        nextPageID: UUID,
        decision: ImportBoundaryOverrideDecision
    ) {
        self.key = ImportBoundaryKey(
            previousPageID: previousPageID,
            nextPageID: nextPageID
        )
        self.decision = decision
    }
}

/// Stable domain reason identifiers. A wire adapter remains responsible for versioning.
enum ImportGroupingReason: String, Codable, CaseIterable, Sendable {
    case userMarkedSameDocument
    case userMarkedNewDocument
    case differentReliableNames
    case differentReportNumber
    case nextPageIsPageOne
    case nextPageHasFirstPageStructure
    case sameReportNumber
    case consecutivePageNumbers
    case sameMultiPagePDFSession
    case sameVisionKitScanSession
    case highOCRLineOverlap
    case likelyDuplicateScreenshot
    case differentHospital
    case differentReportTitle
    case distantEventDate
    case repeatedPageNumber
    case pageNumberReset
    case pageNumberGap
    case conflictingTotalPages
    case sameHospitalWeak
    case sameReportTitleWeak
    case sameEventDateWeak
    case captureTimeNearbyWeak
    case samePhotoSelectionSessionWeak
    case conflictingStrongSignals
    case insufficientEvidence
}

enum ImportGroupIdentityReason: String, Codable, CaseIterable, Sendable {
    case multipleReliableNamesOnSinglePage
    case multipleReliableNamesAcrossPages
    case partiallyOverlappingReliableNames
    case conflictingNamesSeparatedByNamelessPages
}

struct ImportDuplicateScreenshotSuggestion: Hashable, Codable, Sendable {
    let previousPageID: UUID
    let nextPageID: UUID
    let confidence: Double

    /// The grouping engine never deletes or mutates originals.
    let preservesBothOriginals: Bool

    init(previousPageID: UUID, nextPageID: UUID, confidence: Double) {
        self.previousPageID = previousPageID
        self.nextPageID = nextPageID
        self.confidence = min(max(confidence, 0), 1)
        self.preservesBothOriginals = true
    }
}

struct ImportBoundarySuggestion: Hashable, Codable, Sendable {
    let key: ImportBoundaryKey
    let decision: ImportBoundaryDecision
    let confidence: Double
    let reasons: [ImportGroupingReason]
    let OCRLineOverlapScore: Double
    let duplicateScreenshot: ImportDuplicateScreenshotSuggestion?
    let isUserFixed: Bool

    init(
        key: ImportBoundaryKey,
        decision: ImportBoundaryDecision,
        confidence: Double,
        reasons: [ImportGroupingReason],
        OCRLineOverlapScore: Double,
        duplicateScreenshot: ImportDuplicateScreenshotSuggestion?,
        isUserFixed: Bool
    ) {
        self.key = key
        self.decision = decision
        self.confidence = min(max(confidence, 0), 1)
        self.reasons = reasons
        self.OCRLineOverlapScore = min(max(OCRLineOverlapScore, 0), 1)
        self.duplicateScreenshot = duplicateScreenshot
        self.isUserFixed = isUserFixed
    }
}

struct ProvisionalImportGroup: Hashable, Codable, Sendable {
    let groupIndex: Int
    let pageIDs: [UUID]

    /// True when the group was conservatively separated because the preceding
    /// boundary did not have enough evidence. The review UI must call this out.
    let beginsAfterUncertainBoundary: Bool
    let reliableNormalizedNames: [String]
    let requiresIdentityResolution: Bool
    let identityResolutionReasons: [ImportGroupIdentityReason]

    /// Automatic output is advisory and can never be sent straight to commit.
    let requiresExplicitConfirmation: Bool

    init(
        groupIndex: Int,
        pageIDs: [UUID],
        beginsAfterUncertainBoundary: Bool,
        reliableNormalizedNames: [String],
        requiresIdentityResolution: Bool,
        identityResolutionReasons: [ImportGroupIdentityReason]
    ) {
        self.groupIndex = groupIndex
        self.pageIDs = pageIDs
        self.beginsAfterUncertainBoundary = beginsAfterUncertainBoundary
        self.reliableNormalizedNames = reliableNormalizedNames
        self.requiresIdentityResolution = requiresIdentityResolution
        self.identityResolutionReasons = identityResolutionReasons
        self.requiresExplicitConfirmation = true
    }
}

struct ImportGroupingResult: Hashable, Codable, Sendable {
    let schemaVersion: Int
    let orderedPageIDs: [UUID]
    let boundaries: [ImportBoundarySuggestion]
    let groups: [ProvisionalImportGroup]
    let duplicateSuggestions: [ImportDuplicateScreenshotSuggestion]

    /// The result is a review proposal, never a commit authorization.
    let requiresExplicitConfirmation: Bool

    init(
        orderedPageIDs: [UUID],
        boundaries: [ImportBoundarySuggestion],
        groups: [ProvisionalImportGroup],
        duplicateSuggestions: [ImportDuplicateScreenshotSuggestion]
    ) {
        self.schemaVersion = 1
        self.orderedPageIDs = orderedPageIDs
        self.boundaries = boundaries
        self.groups = groups
        self.duplicateSuggestions = duplicateSuggestions
        self.requiresExplicitConfirmation = true
    }
}

enum ImportEvidenceField: String, Codable, Sendable {
    case sourceSessionCharacters
    case sourceSessionUTF8Bytes
    case hospitalCharacters
    case reportTitleCharacters
    case reportNumberCharacters
    case nameCount
    case nameCharacters
    case topOCRLineCount
    case bottomOCRLineCount
    case OCRLineCharacters
    case pageUTF8Bytes
    case batchUTF8Bytes
}

enum ImportGroupingError: Error, Equatable, Sendable {
    case batchPageLimitExceeded(actual: Int, maximum: Int)
    case documentPageLimitExceeded(actual: Int, maximum: Int)
    case duplicatePageID(UUID)
    case negativeSourceOrder(pageID: UUID)
    case duplicateSourceOrder(Int)
    case blankSourceSessionID(pageID: UUID)
    case invalidPageNumber(pageID: UUID)
    case invalidConfidence(pageID: UUID)
    case evidenceLimitExceeded(
        pageID: UUID?,
        field: ImportEvidenceField,
        actual: Int,
        maximum: Int
    )
    case invalidOverride(ImportBoundaryKey)
    case conflictingOverrides(ImportBoundaryKey)
}
