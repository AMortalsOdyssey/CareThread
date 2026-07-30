import Foundation
import Testing
@testable import CareThread

struct ImportGroupingLimitTests {
    private let engine = ImportGroupingEngine()

    @Test("100 页批次被完整接受且不截断")
    func oneHundredPagesAreAcceptedWithoutTruncation() throws {
        let pages = makePages(count: 100, source: .photoSelection)
        let result = try engine.suggest(pages: pages)

        #expect(result.orderedPageIDs.count == 100)
        #expect(result.groups.flatMap(\.pageIDs).count == 100)
    }

    @Test("第 101 页以显式错误拒绝且不返回部分结果")
    func oneHundredOnePagesAreRejected() {
        let pages = makePages(count: 101, source: .photoSelection)
        #expect(throws: ImportGroupingError.batchPageLimitExceeded(
            actual: 101,
            maximum: 100
        )) {
            try engine.suggest(pages: pages)
        }
    }

    @Test("单份 50 页文档被完整接受")
    func fiftyPageDocumentIsAccepted() throws {
        let pages = makePages(
            count: 50,
            source: .multiPagePDF,
            session: "fictional-fifty-page-pdf"
        )
        let result = try engine.suggest(pages: pages)

        #expect(result.groups.count == 1)
        #expect(result.groups[0].pageIDs.count == 50)
    }

    @Test("单份第 51 页以显式错误拒绝且不截断")
    func fiftyOnePageDocumentIsRejected() {
        let pages = makePages(
            count: 51,
            source: .multiPagePDF,
            session: "fictional-fifty-one-page-pdf"
        )
        #expect(throws: ImportGroupingError.documentPageLimitExceeded(
            actual: 51,
            maximum: 50
        )) {
            try engine.suggest(pages: pages)
        }
    }

    @Test("重复页面稳定标识被拒绝")
    func duplicatePageIDIsRejected() {
        let sharedID = deterministicUUID(1)
        let pages = [
            makePage(index: 1, id: sharedID),
            makePage(index: 2, id: sharedID)
        ]
        #expect(throws: ImportGroupingError.duplicatePageID(sharedID)) {
            try engine.suggest(pages: pages)
        }
    }

    @Test("同一边界冲突的用户固定决定被拒绝")
    func conflictingOverridesAreRejected() {
        let pages = makePages(count: 2, source: .photoSelection)
        let merge = ImportBoundaryOverride(
            previousPageID: pages[0].pageID,
            nextPageID: pages[1].pageID,
            decision: .sameDocument
        )
        let split = ImportBoundaryOverride(
            previousPageID: pages[0].pageID,
            nextPageID: pages[1].pageID,
            decision: .newDocument
        )
        #expect(throws: ImportGroupingError.conflictingOverrides(merge.key)) {
            try engine.suggest(pages: pages, overrides: [merge, split])
        }
    }

    @Test("负数 sourceOrder 被拒绝")
    func negativeSourceOrderIsRejected() {
        let page = ImportPageEvidence(
            pageID: deterministicUUID(1),
            sourceOrder: -1,
            sourceSessionID: "negative-order",
            source: .photoSelection
        )
        #expect(throws: ImportGroupingError.negativeSourceOrder(pageID: page.pageID)) {
            try engine.suggest(pages: [page])
        }
    }

    @Test("重复 sourceOrder 被拒绝而不按 UUID 改写邻接")
    func duplicateSourceOrderIsRejected() {
        let pages = [
            makePage(index: 1),
            ImportPageEvidence(
                pageID: deterministicUUID(2),
                sourceOrder: 1,
                sourceSessionID: "duplicate-order",
                source: .photoSelection
            )
        ]
        #expect(throws: ImportGroupingError.duplicateSourceOrder(1)) {
            try engine.suggest(pages: pages)
        }
    }

    @Test("空白 sourceSessionID 被拒绝")
    func blankSessionIsRejected() {
        let page = ImportPageEvidence(
            pageID: deterministicUUID(1),
            sourceOrder: 1,
            sourceSessionID: " \n ",
            source: .photoSelection
        )
        #expect(throws: ImportGroupingError.blankSourceSessionID(pageID: page.pageID)) {
            try engine.suggest(pages: [page])
        }
    }

    @Test("页码和总页数超过合理上限时被拒绝")
    func unreasonablePageNumbersAreRejected() {
        let pageNumber = ImportPageEvidence(
            pageID: deterministicUUID(1),
            sourceOrder: 1,
            sourceSessionID: "page-number-limit",
            source: .multiPagePDF,
            pageNumber: ImportGroupingLimits.maximumPageNumber + 1
        )
        let totalPages = ImportPageEvidence(
            pageID: deterministicUUID(2),
            sourceOrder: 2,
            sourceSessionID: "total-page-limit",
            source: .multiPagePDF,
            totalPages: ImportGroupingLimits.maximumPageNumber + 1
        )

        #expect(throws: ImportGroupingError.invalidPageNumber(pageID: pageNumber.pageID)) {
            try engine.suggest(pages: [pageNumber])
        }
        #expect(throws: ImportGroupingError.invalidPageNumber(pageID: totalPages.pageID)) {
            try engine.suggest(pages: [totalPages])
        }
    }

    @Test("来源会话和元数据字符上限在规范化前执行")
    func metadataLengthLimitsAreEnforced() {
        let sourceSession = ImportPageEvidence(
            pageID: deterministicUUID(1),
            sourceOrder: 1,
            sourceSessionID: String(
                repeating: "s",
                count: ImportGroupingLimits.maximumSourceSessionCharacters + 1
            ),
            source: .photoSelection
        )
        let hospital = ImportPageEvidence(
            pageID: deterministicUUID(2),
            sourceOrder: 2,
            sourceSessionID: "hospital-limit",
            source: .photoSelection,
            hospital: String(
                repeating: "院",
                count: ImportGroupingLimits.maximumHospitalCharacters + 1
            )
        )
        let title = ImportPageEvidence(
            pageID: deterministicUUID(3),
            sourceOrder: 3,
            sourceSessionID: "title-limit",
            source: .photoSelection,
            reportTitle: String(
                repeating: "题",
                count: ImportGroupingLimits.maximumReportTitleCharacters + 1
            )
        )
        let reportNumber = ImportPageEvidence(
            pageID: deterministicUUID(4),
            sourceOrder: 4,
            sourceSessionID: "report-number-limit",
            source: .photoSelection,
            reportNumber: String(
                repeating: "R",
                count: ImportGroupingLimits.maximumReportNumberCharacters + 1
            )
        )

        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [sourceSession])
        }
        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [hospital])
        }
        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [title])
        }
        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [reportNumber])
        }
    }

    @Test("姓名数量和单个姓名长度有硬上限")
    func nameLimitsAreEnforced() {
        let tooMany = ImportPageEvidence(
            pageID: deterministicUUID(1),
            sourceOrder: 1,
            sourceSessionID: "many-names",
            source: .photoSelection,
            names: (0...ImportGroupingLimits.maximumNamesPerPage).map {
                ImportNameEvidence(value: "虚构姓名\($0)", confidence: 0.9)
            }
        )
        let tooLong = ImportPageEvidence(
            pageID: deterministicUUID(2),
            sourceOrder: 2,
            sourceSessionID: "long-name",
            source: .photoSelection,
            names: [
                ImportNameEvidence(
                    value: String(
                        repeating: "名",
                        count: ImportGroupingLimits.maximumNameCharacters + 1
                    ),
                    confidence: 0.9
                )
            ]
        )

        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [tooMany])
        }
        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [tooLong])
        }
    }

    @Test("OCR 行数和单行字符长度有硬上限")
    func OCRLineLimitsAreEnforced() {
        let tooManyLines = ImportPageEvidence(
            pageID: deterministicUUID(1),
            sourceOrder: 1,
            sourceSessionID: "many-lines",
            source: .photoSelection,
            topOCRLines: Array(
                repeating: "虚构行",
                count: ImportGroupingLimits.maximumOCRLinesPerRegion + 1
            )
        )
        let tooLongLine = ImportPageEvidence(
            pageID: deterministicUUID(2),
            sourceOrder: 2,
            sourceSessionID: "long-line",
            source: .photoSelection,
            bottomOCRLines: [
                String(
                    repeating: "字",
                    count: ImportGroupingLimits.maximumOCRLineCharacters + 1
                )
            ]
        )

        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [tooManyLines])
        }
        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: [tooLongLine])
        }
    }

    @Test("组合 Unicode 标量导致单页 UTF8 超限时在分组前拒绝")
    func pageUTF8LimitIsEnforced() {
        let line = String(
            repeating: "🧪",
            count: ImportGroupingLimits.maximumOCRLineCharacters
        )
        let page = ImportPageEvidence(
            pageID: deterministicUUID(1),
            sourceOrder: 1,
            sourceSessionID: "unicode-page-bytes",
            source: .photoSelection,
            topOCRLines: Array(
                repeating: line,
                count: ImportGroupingLimits.maximumOCRLinesPerRegion
            ),
            bottomOCRLines: Array(
                repeating: line,
                count: ImportGroupingLimits.maximumOCRLinesPerRegion
            )
        )

        #expect(throws: ImportGroupingError.evidenceLimitExceeded(
            pageID: page.pageID,
            field: .pageUTF8Bytes,
            actual: 131_090,
            maximum: ImportGroupingLimits.maximumPageUTF8Bytes
        )) {
            try engine.suggest(pages: [page])
        }
    }

    @Test("100 页有界 Unicode 证据可处理且不截断")
    func oneHundredBoundedUnicodePagesAreAccepted() throws {
        let line = String(repeating: "醫🧪", count: 100)
        let pages = (1...100).map { index in
            ImportPageEvidence(
                pageID: deterministicUUID(index),
                sourceOrder: index,
                sourceSessionID: "unicode-\(index)",
                source: .photoSelection,
                topOCRLines: [line]
            )
        }
        let result = try engine.suggest(pages: pages)

        #expect(result.orderedPageIDs.count == 100)
        #expect(result.groups.flatMap(\.pageIDs).count == 100)
    }

    @Test("100 页累计 UTF8 证据超限时显式拒绝")
    func batchUTF8LimitIsEnforced() {
        let line = String(
            repeating: "界",
            count: ImportGroupingLimits.maximumOCRLineCharacters
        )
        let lines = Array(repeating: line, count: 15)
        let pages = (1...100).map { index in
            ImportPageEvidence(
                pageID: deterministicUUID(index),
                sourceOrder: index,
                sourceSessionID: "batch-bytes-\(index)",
                source: .photoSelection,
                topOCRLines: lines,
                bottomOCRLines: lines
            )
        }

        #expect(throws: ImportGroupingError.self) {
            try engine.suggest(pages: pages)
        }
    }

    private func makePages(
        count: Int,
        source: ImportPageSource,
        session: String? = nil
    ) -> [ImportPageEvidence] {
        (1...count).map { index in
            makePage(
                index: index,
                source: source,
                session: session ?? "isolated-\(index)"
            )
        }
    }

    private func makePage(
        index: Int,
        id: UUID? = nil,
        source: ImportPageSource = .photoSelection,
        session: String = "fictional-limit-session"
    ) -> ImportPageEvidence {
        ImportPageEvidence(
            pageID: id ?? deterministicUUID(index),
            sourceOrder: index,
            sourceSessionID: session,
            source: source,
            pageNumber: source == .multiPagePDF ? index : nil,
            totalPages: source == .multiPagePDF ? 100 : nil
        )
    }

    private func deterministicUUID(_ number: Int) -> UUID {
        UUID(uuidString: String(
            format: "A11CE000-0000-0000-0000-%012d",
            number
        ))!
    }
}
