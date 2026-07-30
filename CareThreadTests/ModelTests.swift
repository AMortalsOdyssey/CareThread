import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct ModelTests {
    @Test("患者模型可写入并读取数组值类型")
    func test_patient_whenInserted_roundTripsProfile() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(
            name: "测试患者",
            conditions: ["虚构病种"],
            allergies: ["虚构过敏"],
            histories: [HistoryItem(year: 2020, text: "虚构手术")]
        )
        context.insert(patient)
        try context.save()

        let fetched = try #require(context.fetch(FetchDescriptor<Patient>()).first)
        #expect(fetched.name == "测试患者")
        #expect(fetched.conditions == ["虚构病种"])
        #expect(fetched.histories.first?.year == 2020)
    }

    @Test("记录模型保留机器层与确认层")
    func test_record_whenInserted_roundTripsThreeLayers() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patientId = UUID()
        var extraction = ExtractionResult.empty
        extraction.title = "机器标题"
        extraction.engineIdentifier = "vision"
        let record = MedicalRecord(
            patientId: patientId,
            type: .lab,
            title: "人工标题",
            summary: "人工摘要",
            eventDate: CTDate.make(2026, 3, 15),
            ocrText: "OCR 原文",
            machineExtraction: extraction,
            labItems: [LabItem(name: "TSH", value: 0.08, unit: "mIU/L", flag: .low)],
            reviewStatus: .confirmed
        )
        context.insert(record)
        try context.save()

        let fetched = try #require(context.fetch(FetchDescriptor<MedicalRecord>()).first)
        #expect(fetched.ocrText == "OCR 原文")
        #expect(fetched.machineExtraction?.title == "机器标题")
        #expect(fetched.title == "人工标题")
        #expect(fetched.labItems.first?.flag == .low)
    }

    @Test("删除记录级联删除 SwiftData 附件实体")
    func test_record_whenDeleted_cascadesAttachments() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let record = MedicalRecord(
            patientId: UUID(),
            title: "待删除",
            eventDate: CTDate.make(2026, 1, 1)
        )
        let attachmentID = UUID()
        let attachment = Attachment(
            id: attachmentID,
            patientId: record.patientId,
            fileName: "members/\(record.patientId.uuidString)/records/"
                + "\(record.id.uuidString)/attachments/"
                + "\(attachmentID.uuidString)/original.jpg",
            kind: .image,
            pageIndex: 0,
            record: record
        )
        try record.bindAttachment(attachment)
        context.insert(record)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Attachment>()) == 1)

        context.delete(record)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Attachment>()) == 0)
    }

    @Test("仓库删除记录后调度移除附件字节")
    func test_repository_whenDeletingRecord_removesVaultFiles() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try CaptureVaultService(rootURL: root)
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        context.insert(patient)
        let record = MedicalRecord(
            patientId: patient.id,
            title: "含附件记录",
            eventDate: CTDate.make(2026, 1, 1)
        )
        let attachmentID = UUID()
        let base = "members/\(patient.id.uuidString)/records/"
            + "\(record.id.uuidString)/attachments/\(attachmentID.uuidString)"
        let originalPath = "\(base)/original.jpg"
        let previewPath = "\(base)/preview.jpg"
        let originalURL = try vault.url(for: originalPath)
        let previewURL = try vault.url(for: previewPath)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("image".utf8).write(to: originalURL)
        try Data("preview".utf8).write(to: previewURL)
        try record.bindAttachment(
            Attachment(
                id: attachmentID,
                patientId: record.patientId,
                fileName: previewPath,
                originalFileName: originalPath,
                kind: .image,
                pageIndex: 0,
                record: record
            )
        )
        let repository = RecordRepository(context: context, fileDeletion: vault)
        try repository.insert(record)
        try repository.delete(record)

        #expect(try context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: originalURL.path))
        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
    }

    @Test("剂量调整结束旧记录并创建新版本")
    func test_medication_whenAdjusted_createsVersionChain() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        let old = Medication(
            patientId: patient.id,
            name: "虚构药物",
            doseValue: 100,
            doseUnit: "µg",
            startDate: CTDate.make(2026, 1, 1),
            reminderEnabled: true,
            reminderTimes: [ReminderTime(hour: 8, minute: 0)]
        )
        context.insert(patient)
        context.insert(old)
        try context.save()
        let effectiveDate = CTDate.make(2026, 3, 15)
        let replacement = try RecordRepository(context: context)
            .adjustMedication(old, newDose: 75, effectiveDate: effectiveDate)

        #expect(old.endDate == effectiveDate)
        #expect(!old.isLongTerm)
        #expect(replacement.previousVersionId == old.id)
        #expect(replacement.doseValue == 75)
        #expect(replacement.reminderTimes == old.reminderTimes)
        #expect(try context.fetchCount(FetchDescriptor<Medication>()) == 2)
    }

    @Test("草稿保留附件与机器提取供模式切换后续录")
    func test_captureDraft_whenInserted_roundTripsState() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let draft = CaptureDraft(
            patientId: UUID(),
            batchId: UUID(),
            documentIndex: 0,
            sourceType: .photo,
            attachmentPaths: ["attachments/a.jpg"],
            selectedType: .lab,
            selectedDate: CTDate.make(2026, 7, 30),
            ocrText: "虚构 OCR",
            machineExtraction: .empty
        )
        context.insert(draft)
        try context.save()
        let fetched = try #require(context.fetch(FetchDescriptor<CaptureDraft>()).first)
        #expect(fetched.attachmentPaths == ["attachments/a.jpg"])
        #expect(fetched.selectedType == .lab)
        #expect(fetched.ocrText == "虚构 OCR")
    }
}
