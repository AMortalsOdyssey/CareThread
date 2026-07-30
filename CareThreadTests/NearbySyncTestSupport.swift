import CryptoKit
import Foundation
import SwiftData
@testable import CareThread

@MainActor
struct NearbySyncTestEnvironment {
    let container: ModelContainer
    let context: ModelContext
    let root: URL
    let vault: CaptureVaultService

    static func make() throws -> Self {
        let root = try TestSupport.temporaryDirectory()
        let container = try TestSupport.container()
        return Self(
            container: container,
            context: container.mainContext,
            root: root,
            vault: try CaptureVaultService(
                rootURL: root.appendingPathComponent("Vault", isDirectory: true)
            )
        )
    }

    func seedFullGraph(
        index: Int,
        includeAttachment: Bool = true
    ) throws -> (patientID: UUID, recordID: UUID, attachmentID: UUID?) {
        func id(_ type: Int) -> UUID {
            UUID(
                uuidString: String(
                    format: "%08X-0000-4000-8000-%012d",
                    type,
                    index
                )
            )!
        }
        let patientID = id(0x10000000)
        let recordID = id(0x20000000)
        let attachmentID = id(0x30000000)
        let medicationID = id(0x40000000)
        let orderID = id(0x50000000)
        let followUpID = id(0x60000000)
        let measurementID = id(0x70000000)
        let tagID = id(0x71000000)
        let reminderID = id(0x72000000)
        let auditID = id(0x73000000)
        let revisionID = id(0x74000000)
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))

        let patient = Patient(
            id: patientID,
            displayName: "虚构成员\(index)",
            reportName: "测试名\(index)",
            aliases: ["别名\(index)"],
            birthDate: date.addingTimeInterval(-30 * 365 * 86_400),
            gender: "未说明",
            conditions: ["虚构慢病"],
            allergies: ["虚构过敏"],
            histories: [HistoryItem(year: 2020, text: "虚构史，仅测试")],
            createdAt: date,
            updatedAt: date
        )
        let record = MedicalRecord(
            id: recordID,
            patientId: patientID,
            type: .lab,
            title: "虚构化验单\(index)",
            summary: "测试摘要",
            eventDate: date,
            eventDatePrecision: .day,
            eventTimezoneIdentifier: "Asia/Shanghai",
            hospital: "虚构医院",
            department: "测试科",
            doctor: "测试医生",
            primaryDisease: "虚构病种",
            ageAtEvent: 30,
            sourceType: .file,
            ocrText: "虚构 OCR 文本",
            ocrEngineIdentifier: "test.offline",
            ocrEngineVersion: "1",
            extractionSchemaVersion: 1,
            machineExtractionRevision: 2,
            confirmedRevision: 2,
            confirmedAt: date,
            machineExtraction: nil,
            abnormalFlags: ["H"],
            structuredFields: [KeyValueItem(key: "项目", value: "虚构")],
            reviewStatus: .confirmed,
            isKeyRecord: true,
            inBrief: true,
            createdAt: date,
            updatedAt: date
        )
        let followUp = FollowUp(
            id: followUpID,
            patientId: patientID,
            sourceOrderId: orderID,
            plannedDate: date.addingTimeInterval(86_400),
            items: ["复查虚构项目"],
            reason: "测试",
            bringRecordIds: [recordID],
            compareRecordId: recordID,
            status: .pending,
            resultRecordId: recordID,
            reminderEnabled: true,
            createdAt: date,
            updatedAt: date,
            contentRevision: 2
        )
        let order = MedicalOrder(
            id: orderID,
            patientId: patientID,
            content: "虚构医嘱",
            sourceRecordId: recordID,
            generatedFollowUpId: followUpID,
            isCompleted: false,
            createdAt: date,
            updatedAt: date,
            contentRevision: 1
        )
        let medication = Medication(
            id: medicationID,
            patientId: patientID,
            name: "虚构药",
            doseValue: 1,
            doseUnit: "片",
            frequency: .dailyOne,
            usageNotes: ["餐后"],
            startDate: date,
            isLongTerm: true,
            hospital: "虚构医院",
            sourceRecordId: recordID,
            reminderEnabled: true,
            reminderTimes: [ReminderTime(hour: 8, minute: 0)],
            remainingQuantity: 10,
            lifecycleStatus: .active,
            createdAt: date,
            updatedAt: date,
            contentRevision: 3
        )
        let measurement = LabMeasurement(
            id: measurementID,
            patientId: patientID,
            recordId: recordID,
            displayName: "虚构指标",
            numericValue: 12.3,
            unit: "U",
            referenceLow: 1,
            referenceHigh: 10,
            abnormalState: .high,
            confidence: .high,
            eventDate: date
        )
        let tag = RecordTag(
            id: tagID,
            patientId: patientID,
            recordId: recordID,
            kind: .disease,
            displayValue: "虚构标签"
        )
        let reminder = try ReminderSchedule(
            id: reminderID,
            patientId: patientID,
            kind: .followUp,
            title: "虚构复查提醒",
            schedule: ReminderRule(
                kind: .once,
                startAt: date.addingTimeInterval(86_400),
                timezoneIdentifier: "Asia/Shanghai"
            ),
            revision: 2,
            sourceRecordId: recordID,
            sourceMedicationId: medicationID,
            sourceFollowUpId: followUpID,
            createdAt: date,
            updatedAt: date
        )
        let audit = RecordAssignmentAudit(
            id: auditID,
            capturedForPatientId: patientID,
            assignedPatientId: patientID,
            recordId: recordID,
            detectedName: "测试名\(index)",
            outcome: .match,
            decision: .acceptedMatch,
            engineIdentifier: "test.offline",
            engineVersion: "1",
            createdAt: date
        )
        let before = try StableJSON.encode(record.editableContent())
        var edited = record.editableContent()
        edited.title += "修订"
        let after = try StableJSON.encode(edited)
        let revision = ContentRevision(
            id: revisionID,
            entityKind: .medicalRecord,
            entityId: recordID,
            patientId: patientID,
            revision: 1,
            changedFieldKeys: ["title"],
            beforeContentPayload: before,
            afterContentPayload: after,
            source: .manual,
            actor: .localUser,
            createdAt: date
        )

        context.insert(patient)
        context.insert(record)
        context.insert(medication)
        context.insert(order)
        context.insert(followUp)
        try measurement.bind(to: record)
        try tag.bind(to: record)
        context.insert(measurement)
        context.insert(tag)
        context.insert(reminder)
        context.insert(audit)
        context.insert(revision)

        var returnedAttachmentID: UUID?
        if includeAttachment {
            let data = Data("fictional-medical-original-\(index)".utf8)
            let relative = "members/\(patientID.uuidString)/records/"
                + "\(recordID.uuidString)/attachments/\(attachmentID.uuidString)/original.jpg"
            let url = try vault.url(for: relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            let attachment = try Attachment.verified(
                id: attachmentID,
                patientId: patientID,
                recordId: recordID,
                originalRelativePath: relative,
                displayFileName: "虚构报告.jpg",
                kind: .image,
                pageIndex: 0,
                uniformTypeIdentifier: "public.jpeg",
                byteCount: Int64(data.count),
                sha256: Data(SHA256.hash(data: data)).hexString,
                importedAt: date,
                importSource: .files,
                pixelWidth: 100,
                pixelHeight: 100
            )
            try record.bindAttachment(attachment)
            context.insert(attachment)
            returnedAttachmentID = attachmentID
        }
        try context.save()
        return (patientID, recordID, returnedAttachmentID)
    }
}

@MainActor
struct NearbySyncTestHarness {
    let package: NearbySyncExportPackage
    let staging: TransferStagingStore
    let senderTransport: InMemoryNearbyByteTransport
    let receiverTransport: InMemoryNearbyByteTransport
    let senderCoordinator: NearbySyncSenderCoordinator
    let receiverCoordinator: NearbySyncReceiverCoordinator
}

@MainActor
func makeNearbySyncHarness(
    sender: NearbySyncTestEnvironment,
    receiver: NearbySyncTestEnvironment,
    scope: TransferScope
) throws -> NearbySyncTestHarness {
    let package = try NearbySyncExporter(
        context: sender.context,
        vault: sender.vault,
        temporaryRoot: sender.root.appendingPathComponent("Export", isDirectory: true)
    ).prepare(scope: scope)
    let staging = try TransferStagingStore(
        rootURL: receiver.root.appendingPathComponent("Staging", isDirectory: true),
        minimumFreeSpaceBytes: 0
    )
    let (senderTransport, receiverTransport) =
        InMemoryNearbyByteTransport.makePair()
    let importer = NearbySyncImporter(
        context: receiver.context,
        vault: receiver.vault,
        stagingStore: staging
    )
    let senderCoordinator = try NearbySyncSenderCoordinator(
        transport: senderTransport,
        package: package
    )
    let receiverCoordinator = try NearbySyncReceiverCoordinator(
        transport: receiverTransport,
        stagingStore: staging,
        existingPatientIDs: Set(
            try receiver.context.fetch(FetchDescriptor<Patient>()).map(\.id)
        ),
        importer: importer.commitImporter(userConfirmedManifest: { true })
    )
    return NearbySyncTestHarness(
        package: package,
        staging: staging,
        senderTransport: senderTransport,
        receiverTransport: receiverTransport,
        senderCoordinator: senderCoordinator,
        receiverCoordinator: receiverCoordinator
    )
}

@MainActor
func runNearbySyncHarness(
    _ harness: NearbySyncTestHarness
) async throws -> NearbySyncSenderResult {
    enum SideResult: Sendable {
        case sender(NearbySyncSenderResult)
        case receiver(NearbySyncImportResult)
    }

    let senderCoordinator = harness.senderCoordinator
    let receiverCoordinator = harness.receiverCoordinator
    do {
        return try await withThrowingTaskGroup(
            of: SideResult.self,
            returning: NearbySyncSenderResult.self
        ) { group in
            group.addTask {
                .receiver(
                    try await receiverCoordinator.run(
                        confirmPairing: { _ in true },
                        confirmManifest: { _ in true }
                    )
                )
            }
            group.addTask {
                .sender(
                    try await senderCoordinator.run(
                        confirmPairing: { _ in true }
                    )
                )
            }
            var senderResult: NearbySyncSenderResult?
            var receivedResult = false
            while let result = try await group.next() {
                switch result {
                case let .sender(value):
                    senderResult = value
                case .receiver:
                    receivedResult = true
                }
            }
            guard let senderResult, receivedResult else {
                throw TransferProtocolError.cancelled
            }
            return senderResult
        }
    } catch {
        await senderCoordinator.cancel()
        await receiverCoordinator.cancel()
        throw error
    }
}

@MainActor
func runNearbySyncE2E(
    sender: NearbySyncTestEnvironment,
    receiver: NearbySyncTestEnvironment,
    scope: TransferScope
) async throws -> NearbySyncSenderResult {
    let harness = try makeNearbySyncHarness(
        sender: sender,
        receiver: receiver,
        scope: scope
    )
    defer { harness.package.cleanup() }
    return try await runNearbySyncHarness(harness)
}
