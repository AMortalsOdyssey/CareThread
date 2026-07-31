import Foundation
import SwiftData
import Testing
@testable import CareThread

// Xcode 26.6 起 Swift Testing 自带 Attachment 类型，与 App 模型撞名；本文件内统一指回 App 模型。
private typealias Attachment = CareThread.Attachment

@MainActor
struct ContentRevisionAndIntegrityTests {
    @Test("成员资料编辑同事务追加历史并可撤销最后一次")
    func patientEdit_appendsHistoryAndUndo() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "妈妈", reportName: "王晓芸")
        context.insert(patient)
        try context.save()
        let service = ContentRevisionService(context: context)
        var edited = patient.editableContent()
        edited.displayName = "母亲"
        edited.aliases = ["王小芸"]

        let first = try service.edit(
            patient,
            content: edited,
            changedFieldKeys: ["displayName", "aliases"],
            source: .manual,
            expectedRevision: 0
        )
        #expect(patient.displayName == "母亲")
        #expect(patient.contentRevision == 1)
        #expect(first.beforeContentPayload != first.afterContentPayload)
        #expect(try service.history(for: patient).count == 1)

        let undo = try service.undoLast(patient, expectedRevision: 1)
        #expect(patient.displayName == "妈妈")
        #expect(patient.contentRevision == 2)
        #expect(undo.source == .undo)
        #expect(try service.history(for: patient).count == 2)
    }

    @Test("病历手动更正不覆盖 OCR 原文或原件安全字段")
    func recordEdit_preservesOCRAndOriginalMetadata() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "机器标题",
            eventDate: Date(),
            sourceType: .manual,
            ocrText: "永不覆盖的 OCR 原文"
        )
        let attachmentID = UUID()
        let originalPath = "members/\(patient.id.uuidString)/records/"
            + "\(record.id.uuidString)/attachments/\(attachmentID.uuidString)/original.jpg"
        let attachment = try Attachment.verified(
            id: attachmentID,
            patientId: patient.id,
            recordId: record.id,
            originalRelativePath: originalPath,
            displayFileName: "原始报告.jpg",
            kind: .image,
            pageIndex: 0,
            uniformTypeIdentifier: "public.jpeg",
            byteCount: 128,
            sha256: String(repeating: "a", count: 64),
            importSource: .photoLibrary
        )
        try record.bindAttachment(attachment)
        context.insert(patient)
        context.insert(record)
        try context.save()
        var content = record.editableContent()
        content.title = "人工确认标题"
        content.summary = "人工确认摘要"

        _ = try ContentRevisionService(context: context).edit(
            record,
            content: content,
            changedFieldKeys: ["title", "summary"],
            source: .ocrConfirmation,
            expectedRevision: 0
        )

        #expect(record.title == "人工确认标题")
        #expect(record.ocrText == "永不覆盖的 OCR 原文")
        #expect(record.attachments.first?.sha256 == String(repeating: "a", count: 64))
        #expect(record.attachments.first?.originalRelativePath == originalPath)
    }

    @Test("文本阴性指标绝不映射为 0，人工真 0 保留")
    func textualLabNeverBecomesZero_realZeroSurvives() throws {
        let patientId = UUID()
        let record = MedicalRecord(
            patientId: patientId,
            type: .lab,
            title: "虚构检验",
            eventDate: Date()
        )
        let measurement = LabMeasurement(
            patientId: patientId,
            recordId: record.id,
            displayName: "抗体",
            numericValue: nil,
            textualValue: "阴性",
            eventDate: record.eventDate
        )
        try record.replaceMeasurements(with: [measurement])
        #expect(record.labItems.isEmpty)
        #expect(measurement.textualValue == "阴性")

        var content = measurement.editableContent()
        content.numericValue = 0
        content.textualValue = nil
        measurement.applyEditableContent(content)
        #expect(record.labItems.first?.value == 0)
    }

    @Test("提醒业务编辑递增 revision，Apple adapter 重绑不递增")
    func reminderAdapterBinding_doesNotBumpBusinessRevision() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        let reminder = try ReminderSchedule(
            patientId: patient.id,
            kind: .medication,
            title: "服药",
            schedule: ReminderRule(kind: .daily, startAt: Date(), hour: 8, minute: 0)
        )
        let binding = AppleReminderBinding(
            patientId: patient.id,
            reminderId: reminder.id,
            destination: .localNotification
        )
        context.insert(patient)
        context.insert(reminder)
        context.insert(binding)
        try context.save()
        var content = reminder.editableContent()
        content.title = "早晨服药"

        _ = try ContentRevisionService(context: context).edit(
            reminder,
            content: content,
            changedFieldKeys: ["title"],
            source: .manual,
            expectedRevision: 0
        )
        let businessRevision = reminder.revision
        binding.updateIdentifiers(
            localNotificationIdentifier: "UN-2",
            calendarEventIdentifier: nil
        )
        try context.save()

        #expect(reminder.revision == businessRevision)
        #expect(reminder.contentRevision == 1)
        #expect(binding.localNotificationIdentifier == "UN-2")
    }

    @Test("草稿和页面确认字段独立于 OCR 建议与 OCR 原文")
    func captureEdits_preserveMachineEvidence() throws {
        let batch = ImportBatch(patientId: UUID(), sourceType: .photo)
        let draft = CaptureDraft(
            patientId: batch.patientId,
            batchId: batch.id,
            documentIndex: 0,
            titleSuggestion: "机器标题",
            sourceType: .photo,
            ocrText: "原始 OCR"
        )
        try batch.bindDraft(draft)
        let page = CapturePage(
            patientId: batch.patientId,
            batchId: batch.id,
            draftId: draft.id,
            sourceOrder: 0,
            pageIndex: 0,
            stagingRelativePath: "staging/0.jpg",
            hospitalSuggestion: "机器医院",
            titleSuggestion: "机器页标题"
        )
        try draft.bindPage(page)
        draft.applyEditableContent(
            CaptureDraftEditableContent(
                confirmedTitle: "人工标题",
                selectedType: .lab,
                selectedDate: Date(),
                updatedAt: draft.updatedAt
            )
        )
        page.applyEditableContent(
            CapturePageEditableContent(
                confirmedHospital: "人工医院",
                confirmedDate: Date(),
                confirmedTitle: "人工页标题"
            )
        )

        #expect(draft.titleSuggestion == "机器标题")
        #expect(draft.ocrText == "原始 OCR")
        #expect(draft.confirmedTitle == "人工标题")
        #expect(page.hospitalSuggestion == "机器医院")
        #expect(page.confirmedHospital == "人工医院")
    }

    @Test("版本未知和损坏 payload 显式返回状态并保留原 Data")
    func modelPayload_unknownAndCorruptAreExplicit() throws {
        let unknown = Data(#"{"schemaVersion":99,"value":["a"]}"#.utf8)
        let unknownRead = ModelPayload.read([String].self, from: unknown)
        #expect(unknownRead.status == .unknownVersion(99))
        #expect(unknownRead.originalData == unknown)
        #expect(unknownRead.value == nil)

        let corrupt = Data(#"{"schemaVersion":1,"value":"#.utf8)
        let corruptRead = ModelPayload.read([String].self, from: corrupt)
        #expect(corruptRead.status == .corrupted)
        #expect(corruptRead.originalData == corrupt)
        #expect(throws: ModelPayloadError.encodingFailed) {
            _ = try ModelPayload.encode(ThrowingPayload())
        }
    }

    @Test("verified Attachment 拒绝非法路径、hash 和空内容")
    func verifiedAttachment_validatesSecurityMetadata() {
        #expect(throws: AttachmentValidationError.invalidRelativePath) {
            _ = try Attachment.verified(
                patientId: UUID(),
                originalRelativePath: "../escape.jpg",
                displayFileName: "报告.jpg",
                kind: .image,
                pageIndex: 0,
                uniformTypeIdentifier: "public.jpeg",
                byteCount: 1,
                sha256: String(repeating: "a", count: 64),
                importSource: .files
            )
        }
        #expect(throws: AttachmentValidationError.invalidSHA256) {
            let patientID = UUID()
            let recordID = UUID()
            let attachmentID = UUID()
            _ = try Attachment.verified(
                id: attachmentID,
                patientId: patientID,
                recordId: recordID,
                originalRelativePath: "members/\(patientID.uuidString)/records/"
                    + "\(recordID.uuidString)/attachments/"
                    + "\(attachmentID.uuidString)/original.jpg",
                displayFileName: "报告.jpg",
                kind: .image,
                pageIndex: 0,
                uniformTypeIdentifier: "public.jpeg",
                byteCount: 1,
                sha256: "bad",
                importSource: .files
            )
        }
    }

    @Test("关系替换显式删除孤儿且拒绝跨成员对象")
    func graphReplacement_deletesOrphansAndRejectsCrossMember() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "手填",
            eventDate: Date()
        )
        let first = LabMeasurement(
            patientId: patient.id,
            recordId: record.id,
            displayName: "A",
            numericValue: 1,
            eventDate: record.eventDate
        )
        let second = LabMeasurement(
            patientId: patient.id,
            recordId: record.id,
            displayName: "B",
            numericValue: 2,
            eventDate: record.eventDate
        )
        try record.replaceMeasurements(with: [first, second])
        context.insert(patient)
        context.insert(record)
        try context.save()

        try RecordRepository(context: context).replaceGraph(
            of: record,
            attachments: [],
            measurements: [second],
            tags: []
        )
        #expect(try context.fetchCount(FetchDescriptor<LabMeasurement>()) == 1)

        let wrong = LabMeasurement(
            patientId: UUID(),
            recordId: record.id,
            displayName: "跨成员",
            numericValue: 3,
            eventDate: record.eventDate
        )
        #expect(throws: RecordGraphValidationError.measurementScope) {
            try record.replaceMeasurements(with: [wrong])
        }
    }

    @Test("编辑历史可从重开磁盘容器恢复")
    func revisionHistory_survivesDiskReopen() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("CareThread.sqlite")
        let firstContainer = try TestSupport.persistentContainer(at: storeURL)
        let patient = Patient(name: "初始成员")
        firstContainer.mainContext.insert(patient)
        try firstContainer.mainContext.save()
        var edited = patient.editableContent()
        edited.displayName = "持久化成员"
        _ = try ContentRevisionService(context: firstContainer.mainContext).edit(
            patient,
            content: edited,
            changedFieldKeys: ["displayName"],
            source: .manual,
            expectedRevision: 0
        )

        let reopened = try TestSupport.persistentContainer(at: storeURL)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<ContentRevision>()) == 1)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<Patient>()).first?.displayName == "持久化成员")
    }

    @Test("内容修订保存失败时实体和历史同时回滚")
    func revisionSaveFailure_rollsBackEntityAndAudit() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "原称呼")
        context.insert(patient)
        try context.save()
        var edited = patient.editableContent()
        edited.displayName = "不应保存"
        let service = ContentRevisionService(
            context: context,
            saveAction: { _ in throw ThrowingPayloadError.always }
        )

        #expect(throws: ContentRevisionServiceError.databaseSaveFailed) {
            try service.edit(
                patient,
                content: edited,
                changedFieldKeys: ["displayName"],
                source: .manual,
                expectedRevision: 0
            )
        }
        #expect(patient.displayName == "原称呼")
        #expect(patient.contentRevision == 0)
        #expect(try context.fetchCount(FetchDescriptor<ContentRevision>()) == 0)

        let secondContext = ModelContext(container)
        let persisted = try #require(
            secondContext.fetch(FetchDescriptor<Patient>()).first
        )
        #expect(persisted.displayName == "原称呼")
        #expect(persisted.contentRevision == 0)
    }

    @Test("两 ModelContext 的陈旧修订请求被 CAS 拒绝且不覆盖新值")
    func staleRevisionFromSecondContext_cannotOverwrite() throws {
        let container = try TestSupport.container()
        let seed = Patient(name: "原始称呼")
        container.mainContext.insert(seed)
        try container.mainContext.save()

        let firstContext = ModelContext(container)
        let secondContext = ModelContext(container)
        let first = try #require(
            firstContext.fetch(FetchDescriptor<Patient>()).first
        )
        let stale = try #require(
            secondContext.fetch(FetchDescriptor<Patient>()).first
        )
        var firstEdit = first.editableContent()
        firstEdit.displayName = "先提交的称呼"
        var staleEdit = stale.editableContent()
        staleEdit.displayName = "陈旧覆盖"

        _ = try ContentRevisionService(context: firstContext).edit(
            first,
            content: firstEdit,
            changedFieldKeys: ["displayName"],
            source: .manual,
            expectedRevision: 0
        )
        #expect(
            throws: ContentRevisionServiceError.revisionConflict(
                expected: 0,
                actual: 1
            )
        ) {
            try ContentRevisionService(context: secondContext).edit(
                stale,
                content: staleEdit,
                changedFieldKeys: ["displayName"],
                source: .manual,
                expectedRevision: 0
            )
        }

        let verificationContext = ModelContext(container)
        let persisted = try #require(
            verificationContext.fetch(FetchDescriptor<Patient>()).first
        )
        #expect(persisted.displayName == "先提交的称呼")
        #expect(persisted.contentRevision == 1)
        #expect(
            try verificationContext.fetchCount(
                FetchDescriptor<ContentRevision>()
            ) == 1
        )
    }

    @Test("提醒规则拒绝非法时区、空周计划和无效间隔")
    func reminderRule_rejectsInvalidSchedules() {
        #expect(throws: ReminderRuleValidationError.invalidTimezone) {
            try ReminderRule(
                kind: .once,
                startAt: Date(),
                timezoneIdentifier: "Invalid/Timezone"
            ).validate()
        }
        #expect(throws: ReminderRuleValidationError.weeklyDaysRequired) {
            try ReminderRule(kind: .weekly, startAt: Date()).validate()
        }
        #expect(throws: ReminderRuleValidationError.intervalRequired) {
            try ReminderRule(
                kind: .intervalDays,
                startAt: Date(),
                intervalDays: 0
            ).validate()
        }
    }
}

private struct ThrowingPayload: Codable {
    init() {}

    init(from decoder: Decoder) throws {
        throw ThrowingPayloadError.always
    }

    func encode(to encoder: Encoder) throws {
        throw ThrowingPayloadError.always
    }
}

private enum ThrowingPayloadError: Error {
    case always
}
