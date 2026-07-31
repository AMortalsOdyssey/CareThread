import Foundation
import PDFKit
import SwiftData
import XCTest
@testable import CareThread

/// Produces fictional files that `device-sim-acceptance.sh` exports from the
/// xcresult bundle and validates again from the Mac side.
@MainActor
final class DeviceSimulatorArtifactTests: XCTestCase {
    func testNotificationDestinationUsesExplicitAcceptanceMode() throws {
        let patientID = UUID()
        let destination = try XCTUnwrap(
            CareThreadNotificationDestination(
                userInfo: [
                    "carethread.kind": "medication",
                    "carethread.patient": patientID.uuidString,
                    "carethread.acceptance.mode": "elder"
                ]
            )
        )
        XCTAssertEqual(destination.kind, .medication)
        XCTAssertEqual(destination.patientID, patientID)
        XCTAssertEqual(destination.displayMode, .elder)
    }

    func testNotificationDestinationFallsBackToStoredMode() throws {
        let suite = "DeviceSimulatorNotificationDestination.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DisplayMode.elder.rawValue, forKey: DisplayMode.storageKey)
        let destination = try XCTUnwrap(
            CareThreadNotificationDestination(
                userInfo: ["carethread.kind": "followUp"],
                defaults: defaults
            )
        )
        XCTAssertEqual(destination.kind, .followUp)
        XCTAssertEqual(destination.displayMode, .elder)
    }

    func testNotificationDestinationRejectsUnknownKind() {
        XCTAssertNil(
            CareThreadNotificationDestination(
                userInfo: ["carethread.kind": "unknown"]
            )
        )
    }

    func testExportsInspectableBackupAndPDFArtifacts() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(
            displayName: "虚构验收成员",
            conditions: ["虚构长期情况"]
        )
        context.insert(patient)
        context.insert(
            MedicalRecord(
                patientId: patient.id,
                type: .lab,
                title: "虚构设备验收报告",
                summary: "完全虚构，仅用于设备模拟器验收。",
                eventDate: CTDate.make(2026, 7, 31),
                sourceType: .manual,
                reviewStatus: .confirmed
            )
        )
        try context.save()

        let vault = try CaptureVaultService(
            rootURL: root.appendingPathComponent("Vault", isDirectory: true)
        )
        let package = try BackupExporter(
            context: context,
            vault: vault,
            temporaryRoot: root.appendingPathComponent(
                "backup-exports",
                isDirectory: true
            )
        ).export(scope: .allMembers)
        defer { package.discard() }

        let archiveAttachment = XCTAttachment(
            contentsOfFile: package.archiveURL
        )
        archiveAttachment.name = "CareThread-device-sim-fictional-backup.zip"
        archiveAttachment.lifetime = .keepAlways
        add(archiveAttachment)

        let pdfStore = M7TemporaryExportStore(
            rootURL: root.appendingPathComponent(
                "pdf-exports",
                isDirectory: true
            )
        )
        let pdf = try M7PDFExportService(store: pdfStore).export(
            pdfPayload(patientID: patient.id)
        )
        defer { pdfStore.remove(pdf.fileURL) }
        XCTAssertGreaterThan(pdf.byteCount, 4_096)
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        XCTAssertEqual(PDFDocument(url: pdf.fileURL)?.pageCount, pdf.pageCount)

        let pdfAttachment = XCTAttachment(contentsOfFile: pdf.fileURL)
        pdfAttachment.name = "CareThread-device-sim-fictional.pdf"
        pdfAttachment.lifetime = .keepAlways
        add(pdfAttachment)
    }

    private func pdfPayload(patientID: UUID) -> RecordExportPayload {
        let records = (0..<30).map { index in
            BriefRecordSnapshot(
                id: UUID(),
                patientID: patientID,
                eventDate: CTDate.make(2026, max(1, 7 - index / 5), max(1, 28 - index)),
                title: "虚构设备验收报告 \(index + 1)",
                summary: "完全虚构的病程整理内容，仅用于验证分页、品牌页首和页尾。",
                type: .lab,
                reviewStatus: .confirmed,
                isInBrief: index < 3,
                abnormalFlags: [],
                structuredFields: [
                    KeyValueItem(key: "虚构字段", value: "虚构值 \(index)")
                ],
                measurements: [],
                tags: []
            )
        }
        let input = BriefInput(
            member: BriefMemberSnapshot(
                id: patientID,
                displayName: "虚构验收成员",
                birthDate: CTDate.make(1980, 1, 1),
                conditions: ["虚构长期情况"],
                allergies: [],
                histories: []
            ),
            records: records,
            medications: [],
            followUps: []
        )
        return BriefBuilder.exportPayload(
            input: input,
            preset: .all,
            generatedAt: CTDate.make(2026, 7, 31)
        )
    }
}
