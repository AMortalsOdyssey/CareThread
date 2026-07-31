import CoreImage
import Foundation
import PDFKit
import Testing
import UIKit
import XCTest
@testable import CareThread

@MainActor
struct M7PDFExportTests {
    @Test("PDF 导出存在且大于 4KB 并有分页")
    func createsNonTrivialPDF() throws {
        let directory = try TestSupport.temporaryDirectory()
        let store = M7TemporaryExportStore(rootURL: directory)
        let result = try M7PDFExportService(store: store)
            .export(payload())
        let keepForVisualReview = ProcessInfo.processInfo.environment[
            "CARETHREAD_M7_KEEP_PDF"
        ] == "1"
        if keepForVisualReview {
            print("M7_VISUAL_PDF=\(result.fileURL.path)")
        }
        defer {
            if !keepForVisualReview {
                store.remove(result.fileURL)
            }
        }

        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        #expect(result.fileURL.pathExtension.lowercased() == "pdf")
        #expect(result.byteCount > 4_096)
        #expect(result.pageCount >= 2)
        let text = extractedText(from: result.fileURL)
        #expect(text.contains(CareThreadPDFBranding.productName))
        #expect(text.containsIgnoringLayoutWhitespace("把家人的病程资料"))
        #expect(text.containsIgnoringLayoutWhitespace("安全地串成一条线"))
        #expect(text.contains("扫码了解这个工具"))
        #expect(
            decodedQRCode(from: result.fileURL)
                == CareThreadPDFBranding.officialWebsiteURL.absoluteString
        )
    }

    @Test("PDF 品牌二维码离线编码临时产品页地址")
    func brandQRCodeEncodesCentralWebsiteHook() throws {
        #expect(
            CareThreadPDFBranding.officialWebsiteURL.scheme == "https"
        )
        #expect(
            CareThreadPDFBranding.officialWebsiteURL.host == "github.com"
        )
        #expect(
            CareThreadPDFBranding.officialWebsiteURL.path
                == "/AMortalsOdyssey/CareThread"
        )
        let image = try #require(
            CareThreadPDFBranding.makeQRCode(side: 240)
        )
        let ciImage = try #require(CIImage(image: image))
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(options: [
                    .useSoftwareRenderer: true
                ]),
                options: [
                    CIDetectorAccuracy: CIDetectorAccuracyHigh
                ]
            )
        )
        let feature = try #require(
            detector.features(in: ciImage)
                .compactMap { $0 as? CIQRCodeFeature }
                .first
        )

        #expect(
            feature.messageString
                == CareThreadPDFBranding.officialWebsiteURL.absoluteString
        )
    }

    @Test("PDF 临时副本设置完全保护并排除备份")
    func protectsAndExcludesShareCopyFromBackup() throws {
        let directory = try TestSupport.temporaryDirectory()
        let store = M7TemporaryExportStore(rootURL: directory)
        let result = try M7PDFExportService(store: store)
            .export(payload())
        defer { store.remove(result.fileURL) }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: result.fileURL.path
        )
        let resourceValues = try result.fileURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )

        let reportedProtection = attributes[.protectionKey]
            as? FileProtectionType
        #expect(M7TemporaryExportStore.requiredFileProtection == .complete)
        // APFS-backed devices report the protection class. The simulator's
        // host filesystem may omit it even though setAttributes succeeded.
        #expect(reportedProtection == nil || reportedProtection == .complete)
        #expect(resourceValues.isExcludedFromBackup == true)
    }

    @Test("全空摘要拒绝生成 PDF")
    func rejectsEmptyDocument() throws {
        let memberID = fixedID(1)
        let input = BriefInput(
            member: BriefMemberSnapshot(
                id: memberID,
                displayName: "虚构空成员",
                birthDate: nil,
                conditions: [],
                allergies: [],
                histories: []
            ),
            records: [],
            medications: [],
            followUps: []
        )
        let value = BriefBuilder.exportPayload(
            input: input,
            preset: .all,
            generatedAt: CTDate.make(2026, 7, 31)
        )
        let directory = try TestSupport.temporaryDirectory()

        #expect(throws: M7PDFExportError.emptyDocument) {
            try M7PDFExportService(
                store: M7TemporaryExportStore(rootURL: directory)
            ).export(value)
        }
    }

    @Test("PDF 记录数量使用显式硬上限")
    func rejectsRecordsBeyondExplicitCap() throws {
        #expect(
            throws: M7BriefDataLoaderError.recordLimitExceeded
        ) {
            try M7BriefDataLoader.validateExportRecordCount(
                M7BriefDataLoader.maximumExportRecordCount + 1
            )
        }
        try M7BriefDataLoader.validateExportRecordCount(
            M7BriefDataLoader.maximumExportRecordCount
        )
    }

    @Test("渲染中取消会删除部分 PDF")
    func cancellationDuringRenderingRemovesPartialFile() throws {
        let directory = try TestSupport.temporaryDirectory()
        let store = M7TemporaryExportStore(rootURL: directory)
        let probe = M7CancellationProbe(cancelAtInvocation: 8)

        #expect(throws: CancellationError.self) {
            try M7PDFExportService(
                store: store,
                shouldCancel: { probe.shouldCancel() }
            ).export(payload())
        }
        let remainingPDFs = (
            try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        )?.filter { $0.pathExtension.lowercased() == "pdf" } ?? []
        #expect(remainingPDFs.isEmpty)
        #expect(probe.invocationCount >= 8)
    }

    fileprivate func payload() -> RecordExportPayload {
        let memberID = fixedID(10)
        var records: [BriefRecordSnapshot] = []
        for index in 0..<26 {
            records.append(pdfRecord(index: index, memberID: memberID))
        }
        let input = BriefInput(
            member: BriefMemberSnapshot(
                id: memberID,
                displayName: "虚构成员",
                birthDate: CTDate.make(1990, 1, 1),
                conditions: ["虚构长期情况"],
                allergies: ["虚构成分过敏"],
                histories: [
                    HistoryItem(year: 2020, text: "虚构既往事件")
                ]
            ),
            records: records,
            medications: [
                BriefMedicationSnapshot(
                    id: fixedID(20),
                    patientID: memberID,
                    name: "虚构药物",
                    doseValue: 1,
                    doseUnit: "片",
                    frequency: .dailyOne,
                    weeklyCount: nil,
                    startDate: CTDate.make(2026, 1, 1),
                    endDate: nil,
                    lifecycleStatus: .active
                )
            ],
            followUps: [
                BriefFollowUpSnapshot(
                    id: fixedID(21),
                    patientID: memberID,
                    plannedDate: CTDate.make(2026, 10, 1),
                    items: ["虚构复查项目"],
                    reason: nil,
                    status: .pending
                )
            ],
            questions: ["虚构问题：下一次需要带哪些资料？"]
        )
        return BriefBuilder.exportPayload(
            input: input,
            preset: .all,
            generatedAt: CTDate.make(2026, 7, 31)
        )
    }

    private func pdfRecord(
        index: Int,
        memberID: UUID
    ) -> BriefRecordSnapshot {
        let month = max(1, 7 - index / 5)
        let day = max(1, 28 - index)
        let isAbnormal = index < 3
        let field = KeyValueItem(
            key: "虚构字段",
            value: "虚构值 \(index)"
        )
        let measurement = BriefMeasurementSnapshot(
            name: "虚构指标",
            numericValue: Double(index) + 0.25,
            textualValue: nil,
            unit: "测试单位",
            abnormalState: isAbnormal ? .high : .none
        )
        return BriefRecordSnapshot(
            id: fixedID(100 + index),
            patientID: memberID,
            eventDate: CTDate.make(2026, month, day),
            title: "虚构检验报告 \(index + 1)",
            summary:
                "这是仅用于自动化测试的虚构摘要，包含足够的中文排版内容。"
                + "它不对应任何真实患者、医院、医生或检查结果。",
            type: .lab,
            reviewStatus: .confirmed,
            isInBrief: isAbnormal,
            abnormalFlags: isAbnormal ? ["虚构异常"] : [],
            structuredFields: [field],
            measurements: [measurement],
            tags: []
        )
    }

    private func fixedID(_ suffix: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                800 + suffix
            )
        )!
    }

    private func extractedText(from fileURL: URL) -> String {
        guard let document = PDFDocument(url: fileURL) else { return "" }
        return (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    private func decodedQRCode(from fileURL: URL) -> String? {
        guard let document = PDFDocument(url: fileURL),
              let page = document.page(at: document.pageCount - 1) else {
            return nil
        }
        let image = page.thumbnail(
            of: CGSize(width: 1_190, height: 1_684),
            for: .mediaBox
        )
        guard let ciImage = CIImage(image: image),
              let detector = CIDetector(
                  ofType: CIDetectorTypeQRCode,
                  context: CIContext(options: [
                      .useSoftwareRenderer: true
                  ]),
                  options: [
                      CIDetectorAccuracy: CIDetectorAccuracyHigh
                  ]
              ) else {
            return nil
        }
        return detector.features(in: ciImage)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }
}

private extension String {
    func containsIgnoringLayoutWhitespace(_ expected: String) -> Bool {
        let compactSelf = filter { !$0.isWhitespace }
        let compactExpected = expected.filter { !$0.isWhitespace }
        return compactSelf.contains(compactExpected)
    }
}

private final class M7CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAtInvocation: Int
    private var count = 0

    init(cancelAtInvocation: Int) {
        self.cancelAtInvocation = cancelAtInvocation
    }

    var invocationCount: Int {
        lock.withLock { count }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            count += 1
            return count >= cancelAtInvocation
        }
    }
}

/// Keeps one fictional PDF inside xcresult so layout can be rendered and
/// reviewed outside the simulator sandbox without exposing user data.
@MainActor
final class M7PDFVisualArtifactTests: XCTestCase {
    func testCreatesFictionalPDFVisualArtifact() throws {
        let directory = try TestSupport.temporaryDirectory()
        let store = M7TemporaryExportStore(rootURL: directory)
        let result = try M7PDFExportService(store: store)
            .export(M7PDFExportTests().payload())
        defer { store.remove(result.fileURL) }

        let attachment = XCTAttachment(contentsOfFile: result.fileURL)
        attachment.name = "CareThread-M7-fictional.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
