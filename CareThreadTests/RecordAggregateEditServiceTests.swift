import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct RecordAggregateEditServiceTests {
    @Test("病历字段与疾病标签单事务保存且主病种不重复")
    func aggregateSave_deduplicatesPrimaryDiseaseAndTags() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "原标题",
            eventDate: CTDate.make(2026, 7, 1),
            primaryDisease: "旧病种",
            diseaseTags: ["旧病种", "高血压", "高血压"]
        )
        context.insert(patient)
        context.insert(record)
        try context.save()
        var content = record.editableContent()
        content.title = "人工标题"

        let revision = try RecordAggregateEditService(context: context).save(
            record: record,
            content: content,
            diseaseValues: [" 糖尿病 ", "糖尿病", "高血压", "高血压", "冠心病"],
            changedFieldKeys: ["title"],
            expectedRevision: 0
        )

        #expect(record.title == "人工标题")
        #expect(record.primaryDisease == "糖尿病")
        #expect(Set(record.diseaseTags) == ["高血压", "冠心病"])
        #expect(record.diseaseTags.count == 2)
        #expect(record.contentRevision == 1)
        #expect(revision.changedFieldKeys.contains("diseaseTags"))
        #expect(revision.changedFieldKeys.contains("primaryDisease"))
        #expect(try context.fetchCount(FetchDescriptor<ContentRevision>()) == 1)
    }

    @Test("聚合保存失败回滚病历、标签和修订历史")
    func aggregateSaveFailure_rollsBackEntireGraph() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "提交前",
            eventDate: CTDate.make(2026, 7, 1),
            primaryDisease: "甲",
            diseaseTags: ["乙"]
        )
        context.insert(patient)
        context.insert(record)
        try context.save()
        var content = record.editableContent()
        content.title = "不应落盘"
        let insertedMeasurement = RecordMeasurementEdit(
            content: LabMeasurementEditableContent(
                displayName: "不应落盘指标",
                numericValue: 9.9,
                textualValue: nil,
                unit: "mmol/L",
                referenceLow: 1,
                referenceHigh: 8,
                referenceText: nil,
                abnormalState: .high,
                confidence: .high,
                eventDate: record.eventDate
            )
        )

        #expect(throws: RecordAggregateEditError.databaseSaveFailed) {
            try RecordAggregateEditService(
                context: context,
                saveAction: { _ in throw AggregateTestError.forced }
            ).save(
                record: record,
                content: content,
                diseaseValues: ["丙", "丁"],
                measurementEdits: [insertedMeasurement],
                changedFieldKeys: ["title"],
                expectedRevision: 0
            )
        }

        let verification = ModelContext(container)
        let persisted = try #require(
            verification.fetch(FetchDescriptor<MedicalRecord>()).first
        )
        #expect(persisted.title == "提交前")
        #expect(persisted.primaryDisease == "甲")
        #expect(persisted.diseaseTags == ["乙"])
        #expect(persisted.measurements.isEmpty)
        #expect(persisted.contentRevision == 0)
        #expect(
            try verification.fetchCount(FetchDescriptor<LabMeasurement>()) == 0
        )
        #expect(
            try verification.fetchCount(FetchDescriptor<ContentRevision>()) == 0
        )
    }

    @Test("表单打开时的 baseRevision 能阻止其他 Context 陈旧覆盖")
    func capturedBaseRevision_rejectsStaleForm() throws {
        let container = try TestSupport.container()
        let patient = Patient(name: "成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "原始",
            eventDate: CTDate.make(2026, 7, 1)
        )
        container.mainContext.insert(patient)
        container.mainContext.insert(record)
        try container.mainContext.save()

        let firstContext = ModelContext(container)
        let staleContext = ModelContext(container)
        let first = try #require(
            firstContext.fetch(FetchDescriptor<MedicalRecord>()).first
        )
        let stale = try #require(
            staleContext.fetch(FetchDescriptor<MedicalRecord>()).first
        )
        let capturedBaseRevision = stale.contentRevision
        var firstContent = first.editableContent()
        firstContent.title = "先提交"
        _ = try RecordAggregateEditService(context: firstContext).save(
            record: first,
            content: firstContent,
            diseaseValues: [],
            changedFieldKeys: ["title"],
            expectedRevision: 0
        )
        var staleContent = stale.editableContent()
        staleContent.title = "陈旧覆盖"

        #expect(
            throws: RecordAggregateEditError.revisionConflict(
                expected: capturedBaseRevision,
                actual: 1
            )
        ) {
            try RecordAggregateEditService(context: staleContext).save(
                record: stale,
                content: staleContent,
                diseaseValues: [],
                changedFieldKeys: ["title"],
                expectedRevision: capturedBaseRevision
            )
        }
        let verification = ModelContext(container)
        #expect(
            try verification.fetch(FetchDescriptor<MedicalRecord>()).first?.title
                == "先提交"
        )
    }

    @Test("完整病历字段与检验指标增改删在一个 CAS 事务中落盘")
    func comprehensiveEdit_savesRecordAndMeasurementGraph() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        let record = MedicalRecord(
            patientId: patient.id,
            type: .lab,
            title: "原检验",
            summary: "原摘要",
            eventDate: CTDate.make(2026, 6, 1),
            eventDatePrecision: .day,
            eventTimezoneIdentifier: "Asia/Shanghai",
            hospital: "原医院",
            sourceType: .fixture,
            ocrText: "不可变 OCR",
            ocrEngineIdentifier: "apple-vision",
            reviewStatus: .pending
        )
        let edited = LabMeasurement(
            patientId: patient.id,
            recordId: record.id,
            displayName: "TSH",
            numericValue: 3.2,
            unit: "mIU/L",
            eventDate: record.eventDate
        )
        let deleted = LabMeasurement(
            patientId: patient.id,
            recordId: record.id,
            displayName: "FT4",
            numericValue: 18,
            unit: "pmol/L",
            eventDate: record.eventDate
        )
        try record.replaceMeasurements(with: [edited, deleted])
        context.insert(patient)
        context.insert(record)
        try context.save()

        var content = record.editableContent()
        content.type = .outpatient
        content.title = "人工完整修订"
        content.summary = "只记录事实"
        content.eventDate = CTDate.make(2026, 7, 2)
        content.eventDatePrecision = .exactTime
        content.eventTimezoneIdentifier = "Asia/Shanghai"
        content.hospital = "虚构医院"
        content.department = "内分泌科"
        content.doctor = "虚构医生"
        content.ageAtEvent = 34
        content.abnormalFlags = ["TSH 偏低"]
        content.structuredFields = [
            KeyValueItem(key: "就诊原因", value: "复查")
        ]
        content.reviewStatus = .confirmed
        content.isKeyRecord = true
        content.inBrief = true
        var editedContent = edited.editableContent()
        editedContent.numericValue = 0.08
        editedContent.referenceLow = 0.27
        editedContent.referenceHigh = 4.2
        editedContent.referenceText = "0.27–4.20"
        editedContent.abnormalState = .low
        editedContent.confidence = .low
        editedContent.eventDate = CTDate.make(2026, 7, 1)
        let addedID = UUID()
        let added = RecordMeasurementEdit(
            id: addedID,
            content: LabMeasurementEditableContent(
                displayName: "尿蛋白",
                numericValue: nil,
                textualValue: "阴性",
                unit: "",
                referenceLow: nil,
                referenceHigh: nil,
                referenceText: "阴性",
                abnormalState: .none,
                confidence: .high,
                eventDate: CTDate.make(2026, 7, 2)
            )
        )

        let revision = try RecordAggregateEditService(
            context: context,
            now: { CTDate.make(2026, 7, 3) }
        ).save(
            record: record,
            content: content,
            diseaseValues: ["甲状腺术后", "随访"],
            measurementEdits: [
                RecordMeasurementEdit(id: edited.id, content: editedContent),
                added
            ],
            changedFieldKeys: [],
            expectedRevision: 0
        )

        #expect(record.title == "人工完整修订")
        #expect(record.type == .outpatient)
        #expect(record.eventDatePrecision == .exactTime)
        #expect(record.eventTimezoneIdentifier == "Asia/Shanghai")
        #expect(record.hospital == "虚构医院")
        #expect(record.department == "内分泌科")
        #expect(record.doctor == "虚构医生")
        #expect(record.primaryDisease == "甲状腺术后")
        #expect(record.diseaseTags == ["随访"])
        #expect(record.ageAtEvent == 34)
        #expect(record.abnormalFlags == ["TSH 偏低"])
        #expect(record.structuredFields.first?.key == "就诊原因")
        #expect(record.reviewStatus == .confirmed)
        #expect(record.isKeyRecord)
        #expect(record.inBrief)
        #expect(record.ocrText == "不可变 OCR")
        #expect(record.sourceType == .fixture)
        #expect(Set(record.measurements.map(\.id)) == [edited.id, addedID])
        #expect(edited.numericValue == 0.08)
        #expect(edited.abnormalState == .low)
        #expect(edited.confidence == .low)
        #expect(edited.contentRevision == 1)
        #expect(
            record.measurements.first(where: { $0.id == addedID })?
                .textualValue == "阴性"
        )
        #expect(revision.changedFieldKeys.contains("labMeasurements"))
        #expect(revision.changedFieldKeys.contains("eventDatePrecision"))
        #expect(revision.changedFieldKeys.contains("structuredFields"))
        let revisions = try context.fetch(FetchDescriptor<ContentRevision>())
        #expect(revisions.count == 4)
        #expect(
            revisions.filter { $0.entityKind == .labMeasurement }.count == 3
        )
        #expect(
            try context.fetchCount(FetchDescriptor<LabMeasurement>()) == 2
        )
    }

    @Test("非法年龄、时区、重复字段与非有限指标均在修改前拒绝")
    func invalidBusinessValues_failClosed() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "原记录",
            eventDate: CTDate.make(2026, 7, 1)
        )
        context.insert(patient)
        context.insert(record)
        try context.save()
        let service = RecordAggregateEditService(context: context)

        var invalidAge = record.editableContent()
        invalidAge.ageAtEvent = 131
        #expect(
            throws: RecordAggregateEditError.invalidValue("ageAtEvent")
        ) {
            try service.save(
                record: record,
                content: invalidAge,
                diseaseValues: [],
                changedFieldKeys: [],
                expectedRevision: 0
            )
        }
        var invalidTimezone = record.editableContent()
        invalidTimezone.eventTimezoneIdentifier = "Invalid/Timezone"
        #expect(
            throws: RecordAggregateEditError.invalidValue("eventDate")
        ) {
            try service.save(
                record: record,
                content: invalidTimezone,
                diseaseValues: [],
                changedFieldKeys: [],
                expectedRevision: 0
            )
        }
        var duplicateFields = record.editableContent()
        duplicateFields.structuredFields = [
            KeyValueItem(key: "医院编号", value: "A"),
            KeyValueItem(key: " 医院编号 ", value: "B")
        ]
        #expect(
            throws: RecordAggregateEditError.invalidValue(
                "structuredFields.duplicateKey"
            )
        ) {
            try service.save(
                record: record,
                content: duplicateFields,
                diseaseValues: [],
                changedFieldKeys: [],
                expectedRevision: 0
            )
        }
        let invalidMeasurement = RecordMeasurementEdit(
            content: LabMeasurementEditableContent(
                displayName: "指标",
                numericValue: .nan,
                textualValue: nil,
                unit: "",
                referenceLow: nil,
                referenceHigh: nil,
                referenceText: nil,
                abnormalState: .none,
                confidence: .low,
                eventDate: record.eventDate
            )
        )
        #expect(
            throws: RecordAggregateEditError.invalidValue(
                "labMeasurement.numberOrDate"
            )
        ) {
            try service.save(
                record: record,
                content: record.editableContent(),
                diseaseValues: [],
                measurementEdits: [invalidMeasurement],
                changedFieldKeys: [],
                expectedRevision: 0
            )
        }
        #expect(record.title == "原记录")
        #expect(record.contentRevision == 0)
        #expect(
            try context.fetchCount(FetchDescriptor<ContentRevision>()) == 0
        )
    }

    @Test("检验指标 UUID 已属于其他成员时拒绝跨成员挪用")
    func crossMemberMeasurementID_isRejected() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = Patient(name: "甲")
        let second = Patient(name: "乙")
        let firstRecord = MedicalRecord(
            patientId: first.id,
            title: "甲记录",
            eventDate: CTDate.make(2026, 7, 1)
        )
        let secondRecord = MedicalRecord(
            patientId: second.id,
            title: "乙记录",
            eventDate: CTDate.make(2026, 7, 1)
        )
        let otherMeasurement = LabMeasurement(
            patientId: second.id,
            recordId: secondRecord.id,
            displayName: "其他成员指标",
            numericValue: 1,
            eventDate: secondRecord.eventDate
        )
        try secondRecord.replaceMeasurements(with: [otherMeasurement])
        [first, second].forEach(context.insert)
        [firstRecord, secondRecord].forEach(context.insert)
        try context.save()

        #expect(throws: RecordAggregateEditError.crossPatientScope) {
            try RecordAggregateEditService(context: context).save(
                record: firstRecord,
                content: firstRecord.editableContent(),
                diseaseValues: [],
                measurementEdits: [
                    RecordMeasurementEdit(otherMeasurement)
                ],
                changedFieldKeys: [],
                expectedRevision: 0
            )
        }
        #expect(firstRecord.measurements.isEmpty)
        #expect(otherMeasurement.patientId == second.id)
    }

    @Test("确认修订号属于系统字段，表单不可伪造")
    func immutableConfirmationRevision_isRejected() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "原记录",
            eventDate: CTDate.make(2026, 7, 1),
            confirmedRevision: 3
        )
        context.insert(patient)
        context.insert(record)
        try context.save()
        var content = record.editableContent()
        content.title = "试图同时伪造系统修订号"
        content.confirmedRevision = 99

        #expect(
            throws: RecordAggregateEditError.immutableField(
                "confirmedRevision"
            )
        ) {
            try RecordAggregateEditService(context: context).save(
                record: record,
                content: content,
                diseaseValues: [],
                changedFieldKeys: [],
                expectedRevision: 0
            )
        }
        #expect(record.title == "原记录")
        #expect(record.confirmedRevision == 3)
    }

    @Test("replaceGraph 提交后安排被移除附件的原件与预览清理")
    func graphReplacement_schedulesRemovedAttachmentCleanup() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "有附件",
            eventDate: CTDate.make(2026, 7, 1)
        )
        let first = try makeAttachment(
            patientID: patient.id,
            recordID: record.id,
            pageIndex: 0
        )
        let second = try makeAttachment(
            patientID: patient.id,
            recordID: record.id,
            pageIndex: 1
        )
        try record.bindAttachment(first)
        try record.bindAttachment(second)
        context.insert(patient)
        context.insert(record)
        try context.save()
        let cleanup = CleanupSpy()

        try RecordRepository(
            context: context,
            fileDeletion: cleanup
        ).replaceGraph(
            of: record,
            attachments: [second],
            measurements: [],
            tags: []
        )

        #expect(cleanup.derived == [try #require(first.derivedRelativePath)])
        #expect(cleanup.originals == [first.originalRelativePath])
        #expect(try context.fetchCount(FetchDescriptor<Attachment>()) == 1)
    }

    @Test("无清理执行器时 replaceGraph 在数据库变更前拒绝移除附件")
    func graphReplacement_withoutCleanupExecutorFailsClosed() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "有附件",
            eventDate: CTDate.make(2026, 7, 1)
        )
        let attachment = try makeAttachment(
            patientID: patient.id,
            recordID: record.id,
            pageIndex: 0
        )
        try record.bindAttachment(attachment)
        context.insert(patient)
        context.insert(record)
        try context.save()

        #expect(throws: RecordRepositoryError.attachmentCleanupUnavailable) {
            try RecordRepository(context: context).replaceGraph(
                of: record,
                attachments: [],
                measurements: [],
                tags: []
            )
        }
        #expect(record.attachments.map(\.id) == [attachment.id])
        #expect(try context.fetchCount(FetchDescriptor<Attachment>()) == 1)
    }

    private func makeAttachment(
        patientID: UUID,
        recordID: UUID,
        pageIndex: Int
    ) throws -> Attachment {
        let attachmentID = UUID()
        let root = "members/\(patientID.uuidString)/records/"
            + "\(recordID.uuidString)/attachments/\(attachmentID.uuidString)"
        return try Attachment.verified(
            id: attachmentID,
            patientId: patientID,
            recordId: recordID,
            originalRelativePath: "\(root)/original.jpg",
            derivedRelativePath: "\(root)/preview.jpg",
            displayFileName: "虚构附件.jpg",
            kind: .image,
            pageIndex: pageIndex,
            uniformTypeIdentifier: "public.jpeg",
            byteCount: 64,
            sha256: String(repeating: "a", count: 64),
            importSource: .files
        )
    }
}

private enum AggregateTestError: Error {
    case forced
}

@MainActor
private final class CleanupSpy: AttachmentFileDeleting {
    private(set) var derived = Set<String>()
    private(set) var originals = Set<String>()

    func deleteAttachmentFiles(
        derivedRelativePaths: Set<String>,
        unreferencedOriginalRelativePaths: Set<String>
    ) {
        derived.formUnion(derivedRelativePaths)
        originals.formUnion(unreferencedOriginalRelativePaths)
    }
}
