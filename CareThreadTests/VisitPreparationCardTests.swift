import CoreGraphics
import Foundation
import PDFKit
import Testing
import XCTest
@testable import CareThread

@MainActor
struct VisitPreparationCardTests {
    private let memberID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000a01"
    )!
    private let otherMemberID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000a02"
    )!
    private let now = CTDate.make(2026, 7, 31)

    @Test("空资料只显示基本称呼且不能导出准备卡")
    func emptyStateRejectsExport() throws {
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
        let document = VisitPreparationCardBuilder.build(
            input: input,
            generatedAt: now
        )

        #expect(document.sections.map(\.id) == [.basicInfo])
        #expect(!document.hasExportableContent)
        let directory = try TestSupport.temporaryDirectory()
        #expect(throws: VisitPreparationPDFError.emptyDocument) {
            try VisitPreparationPDFService(
                store: M7TemporaryExportStore(rootURL: directory)
            ).export(document)
        }
    }

    @Test("准备卡覆盖八类可选内容且全部可关闭")
    func supportsEveryOptionalSection() {
        let input = fullInput()
        let document = VisitPreparationCardBuilder.build(
            input: input,
            contact: "虚构家属 000-0000",
            generatedAt: now
        )

        #expect(
            document.sections.map(\.id)
                == VisitPreparationSectionID.allCases
        )
        #expect(document.hasExportableContent)
        #expect(
            document.sections
                .first(where: { $0.id == .careTeam })?
                .items.first?.text.contains("虚构医生") == true
        )

        let disabled = VisitPreparationCardBuilder.build(
            input: input,
            contact: "虚构家属 000-0000",
            selection: VisitPreparationSelection(
                enabledSections: [],
                selectedRecordIDs: []
            ),
            generatedAt: now
        )
        #expect(disabled.sections.isEmpty)
        #expect(!disabled.hasExportableContent)
    }

    @Test("准备卡严格隔离其他成员的记录和用药")
    func isolatesOtherMemberContent() {
        let input = fullInput(includingForeignData: true)
        let selection = VisitPreparationSelection(
            selectedRecordIDs: [
                fixedID(1),
                fixedID(91)
            ]
        )
        let document = VisitPreparationCardBuilder.build(
            input: input,
            contact: "虚构联系人",
            selection: selection,
            generatedAt: now
        )
        let text = document.sections
            .flatMap(\.items)
            .map(\.text)
            .joined(separator: "\n")

        #expect(!text.contains("其他成员"))
        #expect(!text.contains("外部药物"))
        #expect(!text.contains("外部医院"))
        #expect(!text.contains("外部诊断"))
    }

    @Test("准备卡 PDF 恰好一页且大于 4KB")
    func exportsExactlyOneNonTrivialPage() throws {
        let document = VisitPreparationCardBuilder.build(
            input: fullInput(),
            contact: "虚构家属 000-0000",
            generatedAt: now
        )
        let directory = try TestSupport.temporaryDirectory()
        let store = M7TemporaryExportStore(rootURL: directory)
        let result = try VisitPreparationPDFService(store: store)
            .export(document)
        defer { store.remove(result.fileURL) }

        #expect(result.pageCount == 1)
        #expect(result.byteCount > 4_096)
        let pdf = CGPDFDocument(result.fileURL as CFURL)
        #expect(pdf?.numberOfPages == 1)
        let text = PDFDocument(url: result.fileURL)?.page(at: 0)?.string ?? ""
        #expect(text.contains(CareThreadPDFBranding.productName))
        #expect(text.replacingOccurrences(of: " ", with: "")
            .contains("把家人的病程资料"))
        #expect(text.replacingOccurrences(of: " ", with: "")
            .contains("安全地串成一条线"))
        #expect(text.contains("扫码访问官网"))
        #expect(
            decodedQRCode(from: result.fileURL)
                == CareThreadPDFBranding.officialWebsiteURL.absoluteString
        )
    }

    private func decodedQRCode(from fileURL: URL) -> String? {
        guard let document = PDFDocument(url: fileURL),
              let page = document.page(at: 0) else {
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

    @Test("超长资料按固定预算取舍并明确标出省略")
    func truncatesWithExplicitAccounting() throws {
        let records = (0..<30).map { index in
            record(
                id: fixedID(100 + index),
                patientID: memberID,
                title: "虚构关键记录 \(index) "
                    + String(repeating: "很长的人工摘要", count: 24),
                hospital: "虚构医院 \(index)",
                doctor: "虚构医生 \(index)",
                primaryDisease: "虚构情况 \(index)",
                isKey: true
            )
        }
        let input = BriefInput(
            member: BriefMemberSnapshot(
                id: memberID,
                displayName: "虚构长资料成员",
                birthDate: CTDate.make(1980, 1, 1),
                gender: "未填写",
                conditions: (0..<20).map { "虚构病种 \($0)" },
                allergies: (0..<20).map {
                    "虚构过敏 \($0) "
                        + String(repeating: "需要线下人工核对", count: 20)
                },
                histories: []
            ),
            records: records,
            medications: (0..<20).map { index in
                medication(
                    id: fixedID(200 + index),
                    patientID: memberID,
                    name: "虚构药物 \(index)"
                )
            },
            followUps: [],
            questions: (0..<20).map {
                "虚构待问问题 \($0) "
                    + String(repeating: "需要人工确认", count: 24)
            }
        )
        let document = VisitPreparationCardBuilder.build(
            input: input,
            contact: String(repeating: "虚构联系人", count: 30),
            selection: VisitPreparationSelection(
                selectedRecordIDs: Set(records.map(\.id))
            ),
            generatedAt: now
        )

        #expect(
            document.itemCount
                <= VisitPreparationCardPolicy.maximumVisibleItems
        )
        #expect(document.omittedItemCount > 0)
        #expect(document.shortenedItemCount > 0)
        #expect(
            document.sections
                .flatMap(\.items)
                .allSatisfy {
                    $0.text.count
                        <= VisitPreparationCardPolicy.maximumItemCharacters
                }
        )
        #expect(
            String(
                format: Copy.VisitPreparation.omittedCount,
                document.omittedItemCount
            ).contains("\(document.omittedItemCount)")
        )

        let directory = try TestSupport.temporaryDirectory()
        let store = M7TemporaryExportStore(rootURL: directory)
        let result = try VisitPreparationPDFService(store: store)
            .export(document)
        defer { store.remove(result.fileURL) }
        #expect(result.pageCount == 1)
        let text = PDFDocument(url: result.fileURL)?.page(at: 0)?.string ?? ""
        #expect(text.contains("已省略"))
        #expect(text.contains("\(document.omittedItemCount)"))
        #expect(text.contains("由用户自行整理"))
        #expect(text.contains("仅供就诊沟通参考"))
        #expect(text.contains(CareThreadPDFBranding.productName))
    }

    fileprivate func fullInput(
        includingForeignData: Bool = false
    ) -> BriefInput {
        var records = [
            record(
                id: fixedID(1),
                patientID: memberID,
                title: "虚构关键检验",
                hospital: "虚构市医院",
                doctor: "虚构医生",
                primaryDisease: "虚构已有诊断",
                isKey: true
            )
        ]
        var medications = [
            medication(
                id: fixedID(2),
                patientID: memberID,
                name: "虚构当前用药"
            )
        ]
        if includingForeignData {
            records.append(
                record(
                    id: fixedID(91),
                    patientID: otherMemberID,
                    title: "其他成员关键记录",
                    hospital: "外部医院",
                    doctor: "其他成员医生",
                    primaryDisease: "外部诊断",
                    isKey: true
                )
            )
            medications.append(
                medication(
                    id: fixedID(92),
                    patientID: otherMemberID,
                    name: "外部药物"
                )
            )
        }
        return BriefInput(
            member: BriefMemberSnapshot(
                id: memberID,
                displayName: "虚构成员",
                birthDate: CTDate.make(1990, 1, 1),
                gender: "女",
                conditions: ["虚构长期情况"],
                allergies: ["虚构成分过敏"],
                histories: []
            ),
            records: records,
            medications: medications,
            followUps: [],
            questions: ["这次需要携带哪些旧资料？"]
        )
    }

    private func record(
        id: UUID,
        patientID: UUID,
        title: String,
        hospital: String,
        doctor: String,
        primaryDisease: String,
        isKey: Bool
    ) -> BriefRecordSnapshot {
        BriefRecordSnapshot(
            id: id,
            patientID: patientID,
            eventDate: CTDate.make(2026, 7, 1),
            title: title,
            summary: "虚构事实摘要",
            type: .lab,
            reviewStatus: .confirmed,
            isInBrief: isKey,
            abnormalFlags: [],
            structuredFields: [],
            measurements: [],
            tags: [],
            hospital: hospital,
            doctor: doctor,
            primaryDisease: primaryDisease,
            isKeyRecord: isKey
        )
    }

    private func medication(
        id: UUID,
        patientID: UUID,
        name: String
    ) -> BriefMedicationSnapshot {
        BriefMedicationSnapshot(
            id: id,
            patientID: patientID,
            name: name,
            doseValue: 1,
            doseUnit: "片",
            frequency: .dailyOne,
            weeklyCount: nil,
            startDate: CTDate.make(2026, 1, 1),
            endDate: nil,
            lifecycleStatus: .active
        )
    }

    private func fixedID(_ suffix: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                10_000 + suffix
            )
        )!
    }
}

/// Keeps one fictional one-page card inside xcresult for rendered layout QA.
@MainActor
final class VisitPreparationPDFVisualArtifactTests: XCTestCase {
    func testCreatesFictionalVisitPreparationPDFVisualArtifact() throws {
        let directory = try TestSupport.temporaryDirectory()
        let store = M7TemporaryExportStore(rootURL: directory)
        let document = VisitPreparationCardBuilder.build(
            input: VisitPreparationCardTests().fullInput(),
            contact: "虚构家属 000-0000",
            generatedAt: CTDate.make(2026, 7, 31)
        )
        let result = try VisitPreparationPDFService(store: store)
            .export(document)
        defer { store.remove(result.fileURL) }

        let attachment = XCTAttachment(contentsOfFile: result.fileURL)
        attachment.name = "CareThread-visit-preparation-fictional.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
