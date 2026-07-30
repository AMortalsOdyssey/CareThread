import Foundation
import Testing
@testable import CareThread

/// All names, report numbers, hospitals and OCR text in this file are fictional.
struct ImportGroupingEngineTests {
    private let engine = ImportGroupingEngine()

    @Test("单张导入稳定生成一份单页草稿")
    func oneByOne() throws {
        let page = fixturePage(1)
        let result = try engine.suggest(pages: [page])

        #expect(result.orderedPageIDs == [page.pageID])
        #expect(result.boundaries.isEmpty)
        #expect(result.groups.map(\.pageIDs) == [[page.pageID]])
        #expect(result.schemaVersion == 1)
        #expect(result.requiresExplicitConfirmation)
        #expect(result.groups[0].requiresExplicitConfirmation)
    }

    @Test("单份多页 PDF 形成一份有序文档")
    func oneByMany() throws {
        let pages = (1...5).map {
            fixturePage(
                $0,
                source: .multiPagePDF,
                session: "fictional-pdf-a",
                reportNumber: "R-0001",
                pageNumber: $0,
                totalPages: 5
            )
        }
        let result = try engine.suggest(pages: pages)

        #expect(result.groups.count == 1)
        #expect(result.groups[0].pageIDs == pages.map(\.pageID))
        #expect(result.boundaries.allSatisfy { $0.decision == .sameDocument })
    }

    @Test("多份单页报告按首页和不同报告号拆分")
    func manyByOne() throws {
        let pages = (1...4).map {
            fixturePage(
                $0,
                session: "selection",
                reportNumber: "SINGLE-\($0)",
                pageNumber: 1,
                totalPages: 1,
                firstPageScore: 0.95
            )
        }
        let result = try engine.suggest(pages: pages)

        #expect(result.groups.map(\.pageIDs.count) == [1, 1, 1, 1])
        #expect(result.boundaries.allSatisfy { $0.decision == .newDocument })
    }

    @Test("一次导入多份且每份多页时正确形成混合分组")
    func mixedDocuments() throws {
        let pages = [
            fixturePage(1, reportNumber: "MIX-A", pageNumber: 1, totalPages: 2),
            fixturePage(2, reportNumber: "MIX-A", pageNumber: 2, totalPages: 2),
            fixturePage(
                3,
                reportNumber: "MIX-B",
                pageNumber: 1,
                totalPages: 3,
                firstPageScore: 0.9
            ),
            fixturePage(4, reportNumber: "MIX-B", pageNumber: 2, totalPages: 3),
            fixturePage(5, reportNumber: "MIX-B", pageNumber: 3, totalPages: 3)
        ]
        let result = try engine.suggest(pages: pages)

        #expect(result.groups.map(\.pageIDs.count) == [2, 3])
        #expect(result.boundaries.map(\.decision) == [
            .sameDocument, .newDocument, .sameDocument, .sameDocument
        ])
    }

    @Test("首页姓名可由同一 PDF 的无姓名续页继承而不误拆")
    func firstPageNameAndNamelessContinuation() throws {
        let pages = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "name-in-first-page",
                names: [ImportNameEvidence(value: "测试甲", confidence: 0.99)],
                pageNumber: 1,
                totalPages: 3
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "name-in-first-page",
                pageNumber: 2,
                totalPages: 3
            ),
            fixturePage(
                3,
                source: .multiPagePDF,
                session: "name-in-first-page",
                pageNumber: 3,
                totalPages: 3
            )
        ]
        let result = try engine.suggest(pages: pages)
        #expect(result.groups.count == 1)
    }

    @Test("相邻页面出现不同可靠姓名时安全优先拆分")
    func differentReliableNamesSplit() throws {
        let pages = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "conflicting-names",
                names: [ImportNameEvidence(value: "测试甲", confidence: 0.95)]
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "conflicting-names",
                names: [ImportNameEvidence(value: "测试乙", confidence: 0.91)]
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .newDocument)
        #expect(boundary.reasons.contains(.differentReliableNames))
        #expect(boundary.reasons.contains(.conflictingStrongSignals))
    }

    @Test("低可信姓名不触发跨报告硬拆分")
    func unreliableNameIsNotStrongEvidence() throws {
        let pages = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "low-name-confidence",
                names: [ImportNameEvidence(value: "测试甲", confidence: 0.40)]
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "low-name-confidence",
                names: [ImportNameEvidence(value: "测试乙", confidence: 0.70)]
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .sameDocument)
        #expect(!boundary.reasons.contains(.differentReliableNames))
    }

    @Test("连续页码是强同组证据")
    func consecutivePageNumbersGroup() throws {
        let pages = [
            fixturePage(1, pageNumber: 7, totalPages: 9),
            fixturePage(2, pageNumber: 8, totalPages: 9)
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .sameDocument)
        #expect(boundary.reasons.contains(.consecutivePageNumbers))
    }

    @Test("后一页重新出现第一页时强制建议新报告")
    func nextPageOneSplits() throws {
        let pages = [
            fixturePage(1, pageNumber: 4, totalPages: 4),
            fixturePage(2, pageNumber: 1, totalPages: 2)
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .newDocument)
        #expect(boundary.reasons.contains(.nextPageIsPageOne))
    }

    @Test("相同报告号忽略空格标点和全半角差异")
    func normalizedReportNumberGroups() throws {
        let pages = [
            fixturePage(1, reportNumber: "Ｒ－ ２０２６／００１"),
            fixturePage(2, reportNumber: "r2026001")
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .sameDocument)
        #expect(boundary.reasons.contains(.sameReportNumber))
    }

    @Test("不同报告号优先于同一批次并建议拆分")
    func differentReportNumberSplits() throws {
        let pages = [
            fixturePage(
                1,
                source: .visionKitScan,
                session: "scan-session",
                reportNumber: "REPORT-A"
            ),
            fixturePage(
                2,
                source: .visionKitScan,
                session: "scan-session",
                reportNumber: "REPORT-B"
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .newDocument)
        #expect(boundary.reasons.contains(.differentReportNumber))
    }

    @Test("后一页完整首页结构是强拆分证据")
    func firstPageStructureSplits() throws {
        let pages = [
            fixturePage(1, firstPageScore: 0.1),
            fixturePage(2, firstPageScore: 0.92)
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .newDocument)
        #expect(boundary.reasons.contains(.nextPageHasFirstPageStructure))
    }

    @Test("首页结构误判遇到相同报告号时降级为不确定")
    func firstPageStructureConflictIsUncertain() throws {
        let pages = [
            fixturePage(1, reportNumber: "HOME-FALSE-POSITIVE"),
            fixturePage(
                2,
                reportNumber: "HOME-FALSE-POSITIVE",
                firstPageScore: 0.95
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .uncertain)
        #expect(boundary.reasons.contains(.nextPageHasFirstPageStructure))
        #expect(boundary.reasons.contains(.sameReportNumber))
        #expect(boundary.reasons.contains(.conflictingStrongSignals))
    }

    @Test("截图底部与下一张顶部高重叠时建议同报告")
    func overlappingScreenshotsGroup() throws {
        let pages = [
            fixturePage(
                1,
                bottom: ["白细胞 5.20", "红细胞：4.61", "血小板 213"]
            ),
            fixturePage(
                2,
                top: ["红细胞 4.61", "血小板：213", "报告仅供测试"]
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .sameDocument)
        #expect(boundary.OCRLineOverlapScore >= 0.78)
        #expect(boundary.reasons.contains(.highOCRLineOverlap))
    }

    @Test("高度相似的相邻截图只提示重复且保留两份原件")
    func duplicateScreenshotSuggestionNeverDeletes() throws {
        let common = ["虚构医院", "检查报告", "项目甲 1.2", "项目乙 3.4"]
        let pages = [
            fixturePage(
                1,
                reportNumber: "DUP-1",
                pageNumber: 2,
                top: common,
                bottom: common
            ),
            fixturePage(
                2,
                reportNumber: "DUP-1",
                pageNumber: 2,
                top: common,
                bottom: common
            )
        ]
        let result = try engine.suggest(pages: pages)
        let duplicate = try #require(result.duplicateSuggestions.first)

        #expect(duplicate.preservesBothOriginals)
        #expect(duplicate.confidence >= 0.9)
        #expect(result.boundaries[0].reasons.contains(.likelyDuplicateScreenshot))
    }

    @Test("仅内容高度相似但无报告号或明确页码时不提示重复")
    func duplicateRequiresIndependentEvidence() throws {
        let common = ["虚构医院", "检查报告", "项目甲 1.2", "项目乙 3.4"]
        let pages = [
            fixturePage(1, top: common, bottom: common),
            fixturePage(2, top: common, bottom: common)
        ]
        let result = try engine.suggest(pages: pages)

        #expect(result.duplicateSuggestions.isEmpty)
    }

    @Test("硬姓名冲突抑制重复截图建议")
    func identityConflictSuppressesDuplicate() throws {
        let common = ["虚构医院", "检查报告", "项目甲 1.2", "项目乙 3.4"]
        let pages = [
            fixturePage(
                1,
                names: [ImportNameEvidence(value: "测试甲", confidence: 0.99)],
                pageNumber: 2,
                top: common,
                bottom: common
            ),
            fixturePage(
                2,
                names: [ImportNameEvidence(value: "测试乙", confidence: 0.99)],
                pageNumber: 2,
                top: common,
                bottom: common
            )
        ]
        let result = try engine.suggest(pages: pages)

        #expect(result.boundaries[0].decision == .newDocument)
        #expect(result.duplicateSuggestions.isEmpty)
    }

    @Test("重复截图提示本身不构成强同组信号")
    func duplicateSuggestionDoesNotForceMerge() throws {
        let common = ["虚构医院", "检查报告", "项目甲 1.2", "项目乙 3.4"]
        let pages = [
            fixturePage(1, pageNumber: 2, top: common, bottom: common),
            fixturePage(2, pageNumber: 2, top: common, bottom: common)
        ]
        let result = try engine.suggest(pages: pages)

        #expect(result.duplicateSuggestions.count == 1)
        #expect(result.boundaries[0].decision == .uncertain)
        #expect(result.boundaries[0].reasons.contains(.repeatedPageNumber))
    }

    @Test("用户固定拆分覆盖相同报告号和连续页码")
    func fixedSplitCannotBeOverwritten() throws {
        let pages = [
            fixturePage(1, reportNumber: "OVERRIDE", pageNumber: 1, totalPages: 2),
            fixturePage(2, reportNumber: "OVERRIDE", pageNumber: 2, totalPages: 2)
        ]
        let result = try engine.suggest(
            pages: pages,
            overrides: [
                ImportBoundaryOverride(
                    previousPageID: pages[0].pageID,
                    nextPageID: pages[1].pageID,
                    decision: .newDocument
                )
            ]
        )
        let boundary = result.boundaries[0]

        #expect(boundary.decision == .newDocument)
        #expect(boundary.isUserFixed)
        #expect(boundary.confidence == 1)
        #expect(boundary.reasons == [.userMarkedNewDocument])
    }

    @Test("用户固定合并覆盖不同可靠姓名并作为唯一权威")
    func fixedMergeCannotBeOverwritten() throws {
        let pages = [
            fixturePage(
                1,
                names: [ImportNameEvidence(value: "测试甲", confidence: 0.99)]
            ),
            fixturePage(
                2,
                names: [ImportNameEvidence(value: "测试乙", confidence: 0.99)]
            )
        ]
        let result = try engine.suggest(
            pages: pages,
            overrides: [
                ImportBoundaryOverride(
                    previousPageID: pages[0].pageID,
                    nextPageID: pages[1].pageID,
                    decision: .sameDocument
                )
            ]
        )

        #expect(result.groups.count == 1)
        #expect(result.boundaries[0].isUserFixed)
        #expect(result.boundaries[0].reasons == [.userMarkedSameDocument])
    }

    @Test("只有相同医院和相近时间仍保持不确定而不强合并")
    func weakEvidenceRemainsUncertain() throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let pages = [
            fixturePage(
                1,
                hospital: "虚构第一医院",
                capturedAt: time
            ),
            fixturePage(
                2,
                hospital: "虚构第一医院",
                capturedAt: time.addingTimeInterval(30)
            )
        ]
        let result = try engine.suggest(pages: pages)
        let boundary = result.boundaries[0]

        #expect(boundary.decision == .uncertain)
        #expect(boundary.reasons.contains(.sameHospitalWeak))
        #expect(boundary.reasons.contains(.captureTimeNearbyWeak))
        #expect(result.groups.count == 2)
        #expect(result.groups[1].beginsAfterUncertainBoundary)
    }

    @Test("无任何有效证据明确返回不确定")
    func noEvidenceIsUncertain() throws {
        let pages = [fixturePage(1), fixturePage(2)]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .uncertain)
        #expect(boundary.reasons == [.insufficientEvidence])
        #expect((0...1).contains(boundary.confidence))
    }

    @Test("输入乱序时严格按唯一 sourceOrder 恢复采集顺序")
    func orderIsStable() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let pages = [
            fixturePage(3, id: thirdID, sourceOrder: 3),
            fixturePage(2, id: secondID, sourceOrder: 2),
            fixturePage(1, id: firstID, sourceOrder: 1)
        ]
        let result = try engine.suggest(pages: pages)

        #expect(result.orderedPageIDs == [firstID, secondID, thirdID])
    }

    @Test("相同 session 但来源类型不同不产生强同组信号")
    func sameSessionDifferentSourceDoesNotMerge() throws {
        let pages = [
            fixturePage(1, source: .multiPagePDF, session: "shared-token"),
            fixturePage(2, source: .visionKitScan, session: "shared-token")
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .uncertain)
        #expect(!boundary.reasons.contains(.sameMultiPagePDFSession))
        #expect(!boundary.reasons.contains(.sameVisionKitScanSession))
    }

    @Test("不同医院与相同报告号冲突时不得静默合并")
    func differentHospitalConflictsWithSameSignal() throws {
        let pages = [
            fixturePage(
                1,
                hospital: "虚构第一医院",
                reportNumber: "CONFLICT-H"
            ),
            fixturePage(
                2,
                hospital: "虚构第二医院",
                reportNumber: "CONFLICT-H"
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .uncertain)
        #expect(boundary.reasons.contains(.differentHospital))
        #expect(boundary.reasons.contains(.sameReportNumber))
    }

    @Test("相隔很远的报告日期与强同组信号冲突时要求确认")
    func distantDateConflictsWithSameSignal() throws {
        let pages = [
            fixturePage(
                1,
                eventDate: Date(timeIntervalSince1970: 1_700_000_000),
                reportNumber: "CONFLICT-D"
            ),
            fixturePage(
                2,
                eventDate: Date(timeIntervalSince1970: 1_800_000_000),
                reportNumber: "CONFLICT-D"
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .uncertain)
        #expect(boundary.reasons.contains(.distantEventDate))
    }

    @Test("不同报告标题与同一 PDF 会话冲突时要求确认")
    func differentTitleConflictsWithPDFSession() throws {
        let pages = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "title-conflict",
                reportTitle: "虚构检验甲"
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "title-conflict",
                reportTitle: "虚构检查乙"
            )
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .uncertain)
        #expect(boundary.reasons.contains(.differentReportTitle))
        #expect(boundary.reasons.contains(.sameMultiPagePDFSession))
    }

    @Test("姓名空白续页连接两个姓名时组级传递聚合要求身份处理")
    func transitiveNamesSeparatedByBlankPageRequireResolution() throws {
        let pages = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "transitive-name",
                names: [ImportNameEvidence(value: "测试甲", confidence: 0.99)],
                pageNumber: 1,
                totalPages: 3
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "transitive-name",
                pageNumber: 2,
                totalPages: 3
            ),
            fixturePage(
                3,
                source: .multiPagePDF,
                session: "transitive-name",
                names: [ImportNameEvidence(value: "测试乙", confidence: 0.99)],
                pageNumber: 3,
                totalPages: 3
            )
        ]
        let group = try #require(engine.suggest(pages: pages).groups.first)

        #expect(group.requiresIdentityResolution)
        #expect(group.reliableNormalizedNames == ["测试乙", "测试甲"])
        #expect(group.identityResolutionReasons.contains(.multipleReliableNamesAcrossPages))
        #expect(
            group.identityResolutionReasons.contains(
                .conflictingNamesSeparatedByNamelessPages
            )
        )
    }

    @Test("单页识别出多个可靠姓名时组级要求身份处理")
    func multipleNamesOnOnePageRequireResolution() throws {
        let page = fixturePage(
            1,
            names: [
                ImportNameEvidence(value: "测试甲", confidence: 0.95),
                ImportNameEvidence(value: "测试乙", confidence: 0.96)
            ]
        )
        let group = try #require(engine.suggest(pages: [page]).groups.first)

        #expect(group.requiresIdentityResolution)
        #expect(
            group.identityResolutionReasons.contains(.multipleReliableNamesOnSinglePage)
        )
    }

    @Test("页面可靠姓名集合部分相交时组级要求身份处理")
    func partiallyOverlappingNamesRequireResolution() throws {
        let pages = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "partial-name",
                names: [
                    ImportNameEvidence(value: "测试甲", confidence: 0.95),
                    ImportNameEvidence(value: "测试乙", confidence: 0.96)
                ]
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "partial-name",
                names: [
                    ImportNameEvidence(value: "测试乙", confidence: 0.97),
                    ImportNameEvidence(value: "测试丙", confidence: 0.98)
                ]
            )
        ]
        let group = try #require(engine.suggest(pages: pages).groups.first)

        #expect(group.requiresIdentityResolution)
        #expect(
            group.identityResolutionReasons.contains(.partiallyOverlappingReliableNames)
        )
    }

    @Test("连续页可靠姓名完全一致时无需额外身份处理")
    func consistentNameNeedsNoResolution() throws {
        let name = ImportNameEvidence(value: "测试甲", confidence: 0.99)
        let pages = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "same-name",
                names: [name]
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "same-name",
                names: [name]
            )
        ]
        let group = try #require(engine.suggest(pages: pages).groups.first)

        #expect(!group.requiresIdentityResolution)
        #expect(group.identityResolutionReasons.isEmpty)
    }

    @Test("倒序和页码重置返回不确定而不强合并")
    func pageNumberResetIsUncertain() throws {
        let pages = [
            fixturePage(1, pageNumber: 5, totalPages: 8),
            fixturePage(2, pageNumber: 2, totalPages: 8)
        ]
        let boundary = try #require(engine.suggest(pages: pages).boundaries.first)

        #expect(boundary.decision == .uncertain)
        #expect(boundary.reasons.contains(.pageNumberReset))
    }

    @Test("页码重复和总页数冲突均要求确认")
    func repeatedPageAndTotalConflictAreUncertain() throws {
        let repeated = [
            fixturePage(1, pageNumber: 3, totalPages: 5),
            fixturePage(2, pageNumber: 3, totalPages: 5)
        ]
        let totalConflict = [
            fixturePage(
                1,
                source: .multiPagePDF,
                session: "total-conflict",
                pageNumber: 1,
                totalPages: 5
            ),
            fixturePage(
                2,
                source: .multiPagePDF,
                session: "total-conflict",
                pageNumber: 2,
                totalPages: 6
            )
        ]
        let repeatedBoundary = try #require(
            engine.suggest(pages: repeated).boundaries.first
        )
        let totalBoundary = try #require(
            engine.suggest(pages: totalConflict).boundaries.first
        )

        #expect(repeatedBoundary.decision == .uncertain)
        #expect(repeatedBoundary.reasons.contains(.repeatedPageNumber))
        #expect(totalBoundary.decision == .uncertain)
        #expect(totalBoundary.reasons.contains(.conflictingTotalPages))
    }

    @Test("无效的非相邻用户边界被显式拒绝")
    func nonAdjacentOverrideIsRejected() {
        let pages = [fixturePage(1), fixturePage(2), fixturePage(3)]
        let override = ImportBoundaryOverride(
            previousPageID: pages[0].pageID,
            nextPageID: pages[2].pageID,
            decision: .sameDocument
        )

        #expect(throws: ImportGroupingError.invalidOverride(override.key)) {
            try engine.suggest(pages: pages, overrides: [override])
        }
    }

    private func fixturePage(
        _ number: Int,
        id: UUID? = nil,
        sourceOrder: Int? = nil,
        source: ImportPageSource = .photoSelection,
        session: String = "fictional-selection-\(UUID().uuidString)",
        names: [ImportNameEvidence] = [],
        hospital: String? = nil,
        eventDate: Date? = nil,
        capturedAt: Date? = nil,
        reportTitle: String? = nil,
        reportNumber: String? = nil,
        pageNumber: Int? = nil,
        totalPages: Int? = nil,
        top: [String] = [],
        bottom: [String] = [],
        firstPageScore: Double = 0
    ) -> ImportPageEvidence {
        ImportPageEvidence(
            pageID: id ?? deterministicUUID(number),
            sourceOrder: sourceOrder ?? number,
            sourceSessionID: session,
            source: source,
            names: names,
            hospital: hospital,
            eventDate: eventDate,
            capturedAt: capturedAt,
            reportTitle: reportTitle,
            reportNumber: reportNumber,
            pageNumber: pageNumber,
            totalPages: totalPages,
            topOCRLines: top,
            bottomOCRLines: bottom,
            firstPageStructureScore: firstPageScore
        )
    }

    private func deterministicUUID(_ number: Int) -> UUID {
        UUID(uuidString: String(
            format: "F1C71000-0000-0000-0000-%012d",
            number
        ))!
    }
}
