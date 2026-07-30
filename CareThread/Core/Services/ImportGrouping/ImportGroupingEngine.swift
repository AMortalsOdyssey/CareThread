import Foundation

enum ImportGroupingLimits {
    static let maximumBatchPages = 100
    static let maximumDocumentPages = 50
    static let maximumPageNumber = 10_000

    static let maximumSourceSessionCharacters = 128
    static let maximumSourceSessionUTF8Bytes = 512
    static let maximumHospitalCharacters = 256
    static let maximumReportTitleCharacters = 512
    static let maximumReportNumberCharacters = 128
    static let maximumNamesPerPage = 8
    static let maximumNameCharacters = 128
    static let maximumOCRLinesPerRegion = 32
    static let maximumOCRLineCharacters = 512
    static let maximumPageUTF8Bytes = 48 * 1_024
    static let maximumBatchUTF8Bytes = 2 * 1_024 * 1_024
    static let maximumOverlapWindowLines = 12
}

struct ImportGroupingEngine: Sendable {
    private let reliableNameThreshold = 0.85
    private let firstPageThreshold = 0.82
    private let highOverlapThreshold = 0.78
    private let duplicateThreshold = 0.90

    func suggest(
        pages: [ImportPageEvidence],
        overrides: [ImportBoundaryOverride] = []
    ) throws -> ImportGroupingResult {
        // Reject page count before any normalization or result allocation.
        guard pages.count <= ImportGroupingLimits.maximumBatchPages else {
            throw ImportGroupingError.batchPageLimitExceeded(
                actual: pages.count,
                maximum: ImportGroupingLimits.maximumBatchPages
            )
        }

        try validate(pages: pages)
        let orderedPages = pages.sorted { $0.sourceOrder < $1.sourceOrder }
        let overrideMap = try validatedOverrides(overrides, for: orderedPages)
        guard !orderedPages.isEmpty else {
            return ImportGroupingResult(
                orderedPageIDs: [],
                boundaries: [],
                groups: [],
                duplicateSuggestions: []
            )
        }

        var boundaries: [ImportBoundarySuggestion] = []
        boundaries.reserveCapacity(orderedPages.count - 1)
        for index in 1..<orderedPages.count {
            let previous = orderedPages[index - 1]
            let next = orderedPages[index]
            let key = ImportBoundaryKey(
                previousPageID: previous.pageID,
                nextPageID: next.pageID
            )
            boundaries.append(
                suggestion(
                    previous: previous,
                    next: next,
                    override: overrideMap[key]
                )
            )
        }

        let groups = try makeGroups(pages: orderedPages, boundaries: boundaries)
        return ImportGroupingResult(
            orderedPageIDs: orderedPages.map(\.pageID),
            boundaries: boundaries,
            groups: groups,
            duplicateSuggestions: boundaries.compactMap(\.duplicateScreenshot)
        )
    }

    private func validate(pages: [ImportPageEvidence]) throws {
        var pageIDs: Set<UUID> = []
        var sourceOrders: Set<Int> = []
        var batchUTF8Bytes = 0

        for page in pages {
            guard pageIDs.insert(page.pageID).inserted else {
                throw ImportGroupingError.duplicatePageID(page.pageID)
            }
            guard page.sourceOrder >= 0 else {
                throw ImportGroupingError.negativeSourceOrder(pageID: page.pageID)
            }
            guard sourceOrders.insert(page.sourceOrder).inserted else {
                throw ImportGroupingError.duplicateSourceOrder(page.sourceOrder)
            }

            try validateTextLimits(for: page)
            let trimmedSession = page.sourceSessionID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedSession.isEmpty else {
                throw ImportGroupingError.blankSourceSessionID(pageID: page.pageID)
            }

            if let pageNumber = page.pageNumber,
               pageNumber < 1 || pageNumber > ImportGroupingLimits.maximumPageNumber {
                throw ImportGroupingError.invalidPageNumber(pageID: page.pageID)
            }
            if let totalPages = page.totalPages,
               totalPages < 1 ||
               totalPages > ImportGroupingLimits.maximumPageNumber ||
               (page.pageNumber ?? 1) > totalPages {
                throw ImportGroupingError.invalidPageNumber(pageID: page.pageID)
            }
            guard page.firstPageStructureScore.isFinite,
                  (0...1).contains(page.firstPageStructureScore),
                  page.names.allSatisfy({
                      $0.confidence.isFinite && (0...1).contains($0.confidence)
                  }) else {
                throw ImportGroupingError.invalidConfidence(pageID: page.pageID)
            }

            let pageBytes = evidenceUTF8Bytes(page)
            guard pageBytes <= ImportGroupingLimits.maximumPageUTF8Bytes else {
                throw ImportGroupingError.evidenceLimitExceeded(
                    pageID: page.pageID,
                    field: .pageUTF8Bytes,
                    actual: pageBytes,
                    maximum: ImportGroupingLimits.maximumPageUTF8Bytes
                )
            }
            let (newBatchBytes, overflow) = batchUTF8Bytes.addingReportingOverflow(pageBytes)
            guard !overflow, newBatchBytes <= ImportGroupingLimits.maximumBatchUTF8Bytes else {
                throw ImportGroupingError.evidenceLimitExceeded(
                    pageID: nil,
                    field: .batchUTF8Bytes,
                    actual: overflow ? Int.max : newBatchBytes,
                    maximum: ImportGroupingLimits.maximumBatchUTF8Bytes
                )
            }
            batchUTF8Bytes = newBatchBytes
        }
    }

    private func validateTextLimits(for page: ImportPageEvidence) throws {
        try validateLength(
            page.sourceSessionID,
            pageID: page.pageID,
            field: .sourceSessionCharacters,
            maximum: ImportGroupingLimits.maximumSourceSessionCharacters
        )
        let sessionBytes = page.sourceSessionID.utf8.count
        guard sessionBytes <= ImportGroupingLimits.maximumSourceSessionUTF8Bytes else {
            throw ImportGroupingError.evidenceLimitExceeded(
                pageID: page.pageID,
                field: .sourceSessionUTF8Bytes,
                actual: sessionBytes,
                maximum: ImportGroupingLimits.maximumSourceSessionUTF8Bytes
            )
        }
        try validateOptionalLength(
            page.hospital,
            pageID: page.pageID,
            field: .hospitalCharacters,
            maximum: ImportGroupingLimits.maximumHospitalCharacters
        )
        try validateOptionalLength(
            page.reportTitle,
            pageID: page.pageID,
            field: .reportTitleCharacters,
            maximum: ImportGroupingLimits.maximumReportTitleCharacters
        )
        try validateOptionalLength(
            page.reportNumber,
            pageID: page.pageID,
            field: .reportNumberCharacters,
            maximum: ImportGroupingLimits.maximumReportNumberCharacters
        )
        guard page.names.count <= ImportGroupingLimits.maximumNamesPerPage else {
            throw ImportGroupingError.evidenceLimitExceeded(
                pageID: page.pageID,
                field: .nameCount,
                actual: page.names.count,
                maximum: ImportGroupingLimits.maximumNamesPerPage
            )
        }
        for name in page.names {
            try validateLength(
                name.value,
                pageID: page.pageID,
                field: .nameCharacters,
                maximum: ImportGroupingLimits.maximumNameCharacters
            )
        }
        try validateLines(
            page.topOCRLines,
            pageID: page.pageID,
            countField: .topOCRLineCount
        )
        try validateLines(
            page.bottomOCRLines,
            pageID: page.pageID,
            countField: .bottomOCRLineCount
        )
    }

    private func validateLines(
        _ lines: [String],
        pageID: UUID,
        countField: ImportEvidenceField
    ) throws {
        guard lines.count <= ImportGroupingLimits.maximumOCRLinesPerRegion else {
            throw ImportGroupingError.evidenceLimitExceeded(
                pageID: pageID,
                field: countField,
                actual: lines.count,
                maximum: ImportGroupingLimits.maximumOCRLinesPerRegion
            )
        }
        for line in lines {
            try validateLength(
                line,
                pageID: pageID,
                field: .OCRLineCharacters,
                maximum: ImportGroupingLimits.maximumOCRLineCharacters
            )
        }
    }

    private func validateOptionalLength(
        _ value: String?,
        pageID: UUID,
        field: ImportEvidenceField,
        maximum: Int
    ) throws {
        if let value {
            try validateLength(value, pageID: pageID, field: field, maximum: maximum)
        }
    }

    private func validateLength(
        _ value: String,
        pageID: UUID,
        field: ImportEvidenceField,
        maximum: Int
    ) throws {
        let count = value.count
        guard count <= maximum else {
            throw ImportGroupingError.evidenceLimitExceeded(
                pageID: pageID,
                field: field,
                actual: count,
                maximum: maximum
            )
        }
    }

    private func evidenceUTF8Bytes(_ page: ImportPageEvidence) -> Int {
        let strings =
            [page.sourceSessionID, page.hospital, page.reportTitle, page.reportNumber]
                .compactMap { $0 } +
            page.names.map(\.value) +
            page.topOCRLines +
            page.bottomOCRLines

        var result = 0
        for string in strings {
            let (newResult, overflow) = result.addingReportingOverflow(string.utf8.count)
            if overflow { return Int.max }
            result = newResult
        }
        return result
    }

    private func validatedOverrides(
        _ overrides: [ImportBoundaryOverride],
        for pages: [ImportPageEvidence]
    ) throws -> [ImportBoundaryKey: ImportBoundaryOverrideDecision] {
        let adjacency = Set(zip(pages, pages.dropFirst()).map {
            ImportBoundaryKey(previousPageID: $0.pageID, nextPageID: $1.pageID)
        })
        var result: [ImportBoundaryKey: ImportBoundaryOverrideDecision] = [:]
        for override in overrides {
            guard adjacency.contains(override.key) else {
                throw ImportGroupingError.invalidOverride(override.key)
            }
            if let existing = result[override.key], existing != override.decision {
                throw ImportGroupingError.conflictingOverrides(override.key)
            }
            result[override.key] = override.decision
        }
        return result
    }

    private func suggestion(
        previous: ImportPageEvidence,
        next: ImportPageEvidence,
        override: ImportBoundaryOverrideDecision?
    ) -> ImportBoundarySuggestion {
        let key = ImportBoundaryKey(
            previousPageID: previous.pageID,
            nextPageID: next.pageID
        )
        let overlap = TextOverlap.measure(
            previousBottom: previous.bottomOCRLines,
            nextTop: next.topOCRLines
        )

        if let override {
            let decision: ImportBoundaryDecision
            let reason: ImportGroupingReason
            switch override {
            case .sameDocument:
                decision = .sameDocument
                reason = .userMarkedSameDocument
            case .newDocument:
                decision = .newDocument
                reason = .userMarkedNewDocument
            }
            return ImportBoundarySuggestion(
                key: key,
                decision: decision,
                confidence: 1,
                reasons: [reason],
                OCRLineOverlapScore: overlap.score,
                duplicateScreenshot: duplicateSuggestion(
                    previous: previous,
                    next: next,
                    suppressForHardConflict: hasHardNameOrReportConflict(
                        previous: previous,
                        next: next
                    )
                ),
                isUserFixed: true
            )
        }

        var hardSplitSignals: [(ImportGroupingReason, Double)] = []
        var softSplitSignals: [(ImportGroupingReason, Double)] = []
        var sameSignals: [(ImportGroupingReason, Double)] = []
        var conflictSignals: [ImportGroupingReason] = []
        var weakSignals: [ImportGroupingReason] = []

        let previousNames = reliableNames(in: previous)
        let nextNames = reliableNames(in: next)
        let hasNameConflict = !previousNames.isEmpty &&
            !nextNames.isEmpty &&
            previousNames.isDisjoint(with: nextNames)
        if hasNameConflict {
            hardSplitSignals.append((.differentReliableNames, 0.99))
        }

        let previousReportNumber = TextNormalizer.normalizeIdentifier(previous.reportNumber)
        let nextReportNumber = TextNormalizer.normalizeIdentifier(next.reportNumber)
        let hasReportNumberConflict: Bool
        if let previousReportNumber, let nextReportNumber {
            hasReportNumberConflict = previousReportNumber != nextReportNumber
            if hasReportNumberConflict {
                hardSplitSignals.append((.differentReportNumber, 0.98))
            } else {
                sameSignals.append((.sameReportNumber, 0.97))
            }
        } else {
            hasReportNumberConflict = false
        }

        if next.pageNumber == 1 {
            hardSplitSignals.append((.nextPageIsPageOne, 0.97))
        }
        if next.firstPageStructureScore >= firstPageThreshold {
            softSplitSignals.append((.nextPageHasFirstPageStructure, 0.88))
        }

        appendPageNumberSignals(
            previous: previous,
            next: next,
            sameSignals: &sameSignals,
            conflictSignals: &conflictSignals
        )
        appendSourceSignals(
            previous: previous,
            next: next,
            sameSignals: &sameSignals,
            weakSignals: &weakSignals
        )
        if overlap.matchedLineCount >= 2, overlap.score >= highOverlapThreshold {
            sameSignals.append((.highOCRLineOverlap, 0.91))
        }

        appendMetadataSignals(
            previous: previous,
            next: next,
            conflictSignals: &conflictSignals,
            weakSignals: &weakSignals
        )

        let duplicate = duplicateSuggestion(
            previous: previous,
            next: next,
            suppressForHardConflict: hasNameConflict || hasReportNumberConflict
        )
        if duplicate != nil {
            weakSignals.append(.likelyDuplicateScreenshot)
        }

        if !hardSplitSignals.isEmpty {
            var reasons = hardSplitSignals.map(\.0)
            reasons.append(contentsOf: softSplitSignals.map(\.0))
            reasons.append(contentsOf: conflictSignals)
            if !sameSignals.isEmpty {
                reasons.append(.conflictingStrongSignals)
                reasons.append(contentsOf: sameSignals.map(\.0))
            }
            reasons.append(contentsOf: weakSignals)
            let strongest = hardSplitSignals.map(\.1).max() ?? 0.9
            return result(
                key: key,
                decision: .newDocument,
                confidence: sameSignals.isEmpty ? strongest : max(0.8, strongest - 0.08),
                reasons: reasons,
                overlap: overlap,
                duplicate: duplicate
            )
        }

        // A machine-detected "first page" is fallible. Strong continuation evidence
        // therefore downgrades this conflict to explicit review rather than forcing split.
        if !softSplitSignals.isEmpty {
            let reasons =
                softSplitSignals.map(\.0) +
                conflictSignals +
                (sameSignals.isEmpty ? [] : [.conflictingStrongSignals]) +
                sameSignals.map(\.0) +
                weakSignals
            return result(
                key: key,
                decision: sameSignals.isEmpty ? .newDocument : .uncertain,
                confidence: sameSignals.isEmpty ? 0.88 : 0.72,
                reasons: reasons,
                overlap: overlap,
                duplicate: duplicate
            )
        }

        if !conflictSignals.isEmpty {
            let reasons =
                conflictSignals +
                (sameSignals.isEmpty ? [] : [.conflictingStrongSignals]) +
                sameSignals.map(\.0) +
                weakSignals
            return result(
                key: key,
                decision: .uncertain,
                confidence: sameSignals.isEmpty ? 0.68 : 0.74,
                reasons: reasons,
                overlap: overlap,
                duplicate: duplicate
            )
        }

        if !sameSignals.isEmpty {
            return result(
                key: key,
                decision: .sameDocument,
                confidence: sameSignals.map(\.1).max() ?? 0.9,
                reasons: sameSignals.map(\.0) + weakSignals,
                overlap: overlap,
                duplicate: duplicate
            )
        }

        let reasons = weakSignals.isEmpty ? [.insufficientEvidence] : weakSignals
        return result(
            key: key,
            decision: .uncertain,
            confidence: weakSignals.isEmpty
                ? 0.5
                : min(0.7, 0.52 + Double(weakSignals.count) * 0.05),
            reasons: reasons,
            overlap: overlap,
            duplicate: duplicate
        )
    }

    private func result(
        key: ImportBoundaryKey,
        decision: ImportBoundaryDecision,
        confidence: Double,
        reasons: [ImportGroupingReason],
        overlap: TextOverlap.Measurement,
        duplicate: ImportDuplicateScreenshotSuggestion?
    ) -> ImportBoundarySuggestion {
        ImportBoundarySuggestion(
            key: key,
            decision: decision,
            confidence: confidence,
            reasons: deduplicated(reasons),
            OCRLineOverlapScore: overlap.score,
            duplicateScreenshot: duplicate,
            isUserFixed: false
        )
    }

    private func appendPageNumberSignals(
        previous: ImportPageEvidence,
        next: ImportPageEvidence,
        sameSignals: inout [(ImportGroupingReason, Double)],
        conflictSignals: inout [ImportGroupingReason]
    ) {
        let totalsConflict: Bool
        if let previousTotal = previous.totalPages, let nextTotal = next.totalPages {
            totalsConflict = previousTotal != nextTotal
            if totalsConflict {
                conflictSignals.append(.conflictingTotalPages)
            }
        } else {
            totalsConflict = false
        }

        guard let previousPage = previous.pageNumber,
              let nextPage = next.pageNumber else {
            return
        }
        if previousPage == nextPage {
            conflictSignals.append(.repeatedPageNumber)
            return
        }
        if nextPage < previousPage {
            conflictSignals.append(.pageNumberReset)
            return
        }
        let (expectedNext, overflow) = previousPage.addingReportingOverflow(1)
        guard !overflow else {
            conflictSignals.append(.pageNumberGap)
            return
        }
        if nextPage == expectedNext {
            if !totalsConflict {
                sameSignals.append((.consecutivePageNumbers, 0.96))
            }
        } else {
            conflictSignals.append(.pageNumberGap)
        }
    }

    private func appendSourceSignals(
        previous: ImportPageEvidence,
        next: ImportPageEvidence,
        sameSignals: inout [(ImportGroupingReason, Double)],
        weakSignals: inout [ImportGroupingReason]
    ) {
        guard previous.sourceSessionID == next.sourceSessionID,
              previous.source == next.source else {
            return
        }
        switch previous.source {
        case .multiPagePDF:
            sameSignals.append((.sameMultiPagePDFSession, 0.96))
        case .visionKitScan:
            sameSignals.append((.sameVisionKitScanSession, 0.93))
        case .photoSelection:
            weakSignals.append(.samePhotoSelectionSessionWeak)
        case .cameraCapture:
            break
        }
    }

    private func appendMetadataSignals(
        previous: ImportPageEvidence,
        next: ImportPageEvidence,
        conflictSignals: inout [ImportGroupingReason],
        weakSignals: inout [ImportGroupingReason]
    ) {
        appendTextComparison(
            previous.hospital,
            next.hospital,
            same: .sameHospitalWeak,
            different: .differentHospital,
            conflictSignals: &conflictSignals,
            weakSignals: &weakSignals
        )
        appendTextComparison(
            previous.reportTitle,
            next.reportTitle,
            same: .sameReportTitleWeak,
            different: .differentReportTitle,
            conflictSignals: &conflictSignals,
            weakSignals: &weakSignals
        )
        if let previousDate = previous.eventDate, let nextDate = next.eventDate {
            if abs(previousDate.timeIntervalSince(nextDate)) <= 36 * 60 * 60 {
                weakSignals.append(.sameEventDateWeak)
            } else {
                conflictSignals.append(.distantEventDate)
            }
        }
        if let previousCapture = previous.capturedAt, let nextCapture = next.capturedAt,
           abs(previousCapture.timeIntervalSince(nextCapture)) <= 10 * 60 {
            weakSignals.append(.captureTimeNearbyWeak)
        }
    }

    private func appendTextComparison(
        _ previous: String?,
        _ next: String?,
        same: ImportGroupingReason,
        different: ImportGroupingReason,
        conflictSignals: inout [ImportGroupingReason],
        weakSignals: inout [ImportGroupingReason]
    ) {
        guard let previous = TextNormalizer.normalizedOptional(previous),
              let next = TextNormalizer.normalizedOptional(next) else {
            return
        }
        if previous == next {
            weakSignals.append(same)
        } else {
            conflictSignals.append(different)
        }
    }

    private func hasHardNameOrReportConflict(
        previous: ImportPageEvidence,
        next: ImportPageEvidence
    ) -> Bool {
        let previousNames = reliableNames(in: previous)
        let nextNames = reliableNames(in: next)
        if !previousNames.isEmpty,
           !nextNames.isEmpty,
           previousNames.isDisjoint(with: nextNames) {
            return true
        }
        if let previousReport = TextNormalizer.normalizeIdentifier(previous.reportNumber),
           let nextReport = TextNormalizer.normalizeIdentifier(next.reportNumber),
           previousReport != nextReport {
            return true
        }
        return false
    }

    private func reliableNames(in page: ImportPageEvidence) -> Set<String> {
        Set(
            page.names.compactMap { evidence in
                guard evidence.confidence >= reliableNameThreshold else { return nil }
                return TextNormalizer.normalizePersonName(evidence.value)
            }
        )
    }

    private func duplicateSuggestion(
        previous: ImportPageEvidence,
        next: ImportPageEvidence,
        suppressForHardConflict: Bool
    ) -> ImportDuplicateScreenshotSuggestion? {
        guard !suppressForHardConflict else { return nil }

        let previousReport = TextNormalizer.normalizeIdentifier(previous.reportNumber)
        let nextReport = TextNormalizer.normalizeIdentifier(next.reportNumber)
        let reportNumberMatches =
            previousReport != nil &&
            previousReport == nextReport
        let pageNumberMatches: Bool
        if let previousPage = previous.pageNumber, let nextPage = next.pageNumber {
            pageNumberMatches = previousPage == nextPage
        } else {
            pageNumberMatches = false
        }
        guard reportNumberMatches || pageNumberMatches else { return nil }

        let previousLines = TextNormalizer.normalizedLines(
            previous.topOCRLines + previous.bottomOCRLines
        )
        let nextLines = TextNormalizer.normalizedLines(
            next.topOCRLines + next.bottomOCRLines
        )
        guard previousLines.count >= 4, nextLines.count >= 4 else {
            return nil
        }
        let contentSimilarity = TextOverlap.setSimilarity(previousLines, nextLines)
        guard contentSimilarity >= duplicateThreshold else { return nil }
        return ImportDuplicateScreenshotSuggestion(
            previousPageID: previous.pageID,
            nextPageID: next.pageID,
            confidence: contentSimilarity
        )
    }

    private struct RawGroup {
        var pages: [ImportPageEvidence]
        let beginsAfterUncertainBoundary: Bool
    }

    private func makeGroups(
        pages: [ImportPageEvidence],
        boundaries: [ImportBoundarySuggestion]
    ) throws -> [ProvisionalImportGroup] {
        guard let first = pages.first else { return [] }
        var rawGroups = [
            RawGroup(pages: [first], beginsAfterUncertainBoundary: false)
        ]
        for (index, boundary) in boundaries.enumerated() {
            let page = pages[index + 1]
            if boundary.decision == .sameDocument {
                rawGroups[rawGroups.count - 1].pages.append(page)
            } else {
                rawGroups.append(
                    RawGroup(
                        pages: [page],
                        beginsAfterUncertainBoundary: boundary.decision == .uncertain
                    )
                )
            }
        }

        if let oversized = rawGroups.first(where: {
            $0.pages.count > ImportGroupingLimits.maximumDocumentPages
        }) {
            throw ImportGroupingError.documentPageLimitExceeded(
                actual: oversized.pages.count,
                maximum: ImportGroupingLimits.maximumDocumentPages
            )
        }

        return rawGroups.enumerated().map { index, raw in
            let identity = identityAssessment(for: raw.pages)
            return ProvisionalImportGroup(
                groupIndex: index,
                pageIDs: raw.pages.map(\.pageID),
                beginsAfterUncertainBoundary: raw.beginsAfterUncertainBoundary,
                reliableNormalizedNames: identity.names,
                requiresIdentityResolution: !identity.reasons.isEmpty,
                identityResolutionReasons: identity.reasons
            )
        }
    }

    private func identityAssessment(
        for pages: [ImportPageEvidence]
    ) -> (names: [String], reasons: [ImportGroupIdentityReason]) {
        let pageNameSets = pages.map(reliableNames)
        let nonEmptySets = pageNameSets.filter { !$0.isEmpty }
        let allNames = nonEmptySets.reduce(into: Set<String>()) {
            $0.formUnion($1)
        }
        var reasonSet: Set<ImportGroupIdentityReason> = []

        if pageNameSets.contains(where: { $0.count > 1 }) {
            reasonSet.insert(.multipleReliableNamesOnSinglePage)
        }
        if nonEmptySets.count > 1, allNames.count > 1 {
            reasonSet.insert(.multipleReliableNamesAcrossPages)
        }
        for leftIndex in pageNameSets.indices {
            for rightIndex in pageNameSets.index(after: leftIndex)..<pageNameSets.endIndex {
                let left = pageNameSets[leftIndex]
                let right = pageNameSets[rightIndex]
                if !left.isEmpty,
                   !right.isEmpty,
                   left != right,
                   !left.isDisjoint(with: right) {
                    reasonSet.insert(.partiallyOverlappingReliableNames)
                }
            }
        }

        var previousNamedIndex: Int?
        var previousNames: Set<String>?
        for (index, names) in pageNameSets.enumerated() where !names.isEmpty {
            if let previousNamedIndex,
               let previousNames,
               index - previousNamedIndex > 1,
               previousNames.isDisjoint(with: names) {
                reasonSet.insert(.conflictingNamesSeparatedByNamelessPages)
            }
            previousNamedIndex = index
            previousNames = names
        }

        let reasons = ImportGroupIdentityReason.allCases.filter(reasonSet.contains)
        return (allNames.sorted(), reasons)
    }

    private func deduplicated(
        _ reasons: [ImportGroupingReason]
    ) -> [ImportGroupingReason] {
        var seen: Set<ImportGroupingReason> = []
        return reasons.filter { seen.insert($0).inserted }
    }
}

enum TextNormalizer {
    static func normalizePersonName(_ value: String) -> String? {
        normalizedOptional(value)
    }

    static func normalizeIdentifier(_ value: String?) -> String? {
        normalizedOptional(value)
    }

    static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalize(value)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_Hans_CN")
            )
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func normalizedLines(_ lines: [String]) -> [String] {
        lines.compactMap(normalizedOptional)
    }
}

private enum TextOverlap {
    struct Measurement {
        let score: Double
        let matchedLineCount: Int
    }

    static func measure(
        previousBottom: [String],
        nextTop: [String]
    ) -> Measurement {
        // Work is deliberately bounded even if the accepted evidence is at its limit.
        let previous = TextNormalizer.normalizedLines(
            Array(previousBottom.suffix(ImportGroupingLimits.maximumOverlapWindowLines))
        )
        let next = TextNormalizer.normalizedLines(
            Array(nextTop.prefix(ImportGroupingLimits.maximumOverlapWindowLines))
        )
        guard !previous.isEmpty, !next.isEmpty else {
            return Measurement(score: 0, matchedLineCount: 0)
        }

        var best = Measurement(score: 0, matchedLineCount: 0)
        let maximumLength = min(previous.count, next.count)
        for length in 1...maximumLength {
            let suffix = previous.suffix(length)
            let prefix = next.prefix(length)
            let lineScores = zip(suffix, prefix).map(lineSimilarity)
            let matched = lineScores.filter { $0 >= 0.80 }.count
            let score = lineScores.reduce(0, +) / Double(length)
            if matched >= best.matchedLineCount, score > best.score {
                best = Measurement(score: score, matchedLineCount: matched)
            }
        }
        return best
    }

    static func setSimilarity(_ left: [String], _ right: [String]) -> Double {
        let leftSet = Set(left)
        let rightSet = Set(right)
        guard !leftSet.isEmpty, !rightSet.isEmpty else { return 0 }
        return 2 * Double(leftSet.intersection(rightSet).count) /
            Double(leftSet.count + rightSet.count)
    }

    private static func lineSimilarity(_ left: String, _ right: String) -> Double {
        if left == right { return 1 }
        let leftGrams = characterBigrams(left)
        let rightGrams = characterBigrams(right)
        guard !leftGrams.isEmpty, !rightGrams.isEmpty else { return 0 }
        return 2 * Double(leftGrams.intersection(rightGrams).count) /
            Double(leftGrams.count + rightGrams.count)
    }

    private static func characterBigrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count >= 2 else {
            return characters.isEmpty ? [] : [String(characters[0])]
        }
        return Set(
            zip(characters, characters.dropFirst()).map {
                String([$0, $1])
            }
        )
    }
}
