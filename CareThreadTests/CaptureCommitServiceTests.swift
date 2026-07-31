import Foundation
import SwiftData
import Testing
@testable import CareThread

private typealias Attachment = CareThread.Attachment

@MainActor
struct CaptureCommitServiceTests {
    @Test("成员称呼不能冒充报告姓名证据")
    func displayNameAlone_doesNotMatchOCRIdentity() throws {
        let patient = Patient(name: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .photo)
        let draft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [
                [DetectedNameCandidate(
                    name: "王晓芸",
                    confidence: 0.99,
                    isReliable: true
                )]
            ]
        )

        #expect(try CaptureNameEvidenceAggregator.evaluate(
            draft: draft,
            frozenPatient: patient
        ).outcome == .mismatch)
    }

    @Test("多页文档首屏有姓名、后页无姓名时整份匹配并原子提交审计")
    func firstPageMatch_laterNoEvidence_commitsRecordAndAudit() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "妈妈", reportName: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .photo)
        let draft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [
                [DetectedNameCandidate(name: "王晓芸", confidence: 0.98, isReliable: true)],
                []
            ]
        )
        context.insert(patient)
        context.insert(batch)
        try context.save()
        let record = MedicalRecord(
            patientId: patient.id,
            title: "虚构报告",
            eventDate: Date(),
            sourceType: .photo
        )

        let audit = try CaptureCommitService(context: context).commit(
            CaptureCommitRequest(
                draftId: draft.id,
                expectedGeneration: draft.generation,
                expectedOutcome: .match,
                decision: .acceptedMatch,
                assignedPatientId: patient.id,
                record: record,
                engineIdentifier: "vision",
                engineVersion: "18.6"
            )
        )

        #expect(audit.outcome == .match)
        #expect(audit.recordId == record.id)
        #expect(try context.fetchCount(FetchDescriptor<MedicalRecord>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<RecordAssignmentAudit>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CaptureDraft>()) == 0)
        let secondContext = ModelContext(container)
        #expect(try secondContext.fetchCount(FetchDescriptor<RecordAssignmentAudit>()) == 1)
    }

    @Test("同批次不同文档不继承姓名证据")
    func separateDocuments_doNotInheritEvidence() throws {
        let patient = Patient(name: "妈妈", reportName: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .file)
        let namedDraft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [
                [DetectedNameCandidate(name: "王晓芸", confidence: 0.99, isReliable: true)]
            ]
        )
        let unnamedDraft = try makeDraft(
            batch: batch,
            documentIndex: 1,
            pageCandidates: [[]]
        )

        #expect(try CaptureNameEvidenceAggregator.evaluate(
            draft: namedDraft,
            frozenPatient: patient
        ).outcome == .match)
        #expect(try CaptureNameEvidenceAggregator.evaluate(
            draft: unnamedDraft,
            frozenPatient: patient
        ).outcome == .noEvidence)
    }

    @Test("同一文档多页出现不同可靠姓名时判 ambiguous")
    func conflictingNames_areAmbiguous() throws {
        let patient = Patient(name: "成员", reportName: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .file)
        let draft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [
                [DetectedNameCandidate(name: "王晓芸", confidence: 0.99, isReliable: true)],
                [DetectedNameCandidate(name: "李明", confidence: 0.97, isReliable: true)]
            ]
        )
        let evidence = try CaptureNameEvidenceAggregator.evaluate(
            draft: draft,
            frozenPatient: patient
        )
        #expect(evidence.outcome == .ambiguous)
        #expect(evidence.reliableNormalizedNames == ["王晓芸", "李明"])
    }

    @Test("页面重排后 pageIndex 连续稳定并使旧 OCR generation 失效")
    func reorderPages_invalidatesLateOCR() throws {
        let patient = Patient(name: "成员", reportName: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .file)
        let draft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [[], [], []]
        )
        let oldGeneration = draft.generation
        let reversed = Array(draft.pages.reversed())
        try draft.reorderPages(reversed)

        #expect(draft.pages.map(\.pageIndex) == [0, 1, 2])
        #expect(draft.generation == oldGeneration + 1)
        #expect(throws: CaptureGroupingError.generationMismatch) {
            try CaptureNameEvidenceAggregator.evaluate(draft: draft, frozenPatient: patient)
        }
    }

    @Test("页不能绑定到不同成员、批次或文档")
    func pageBinding_rejectsCrossScope() throws {
        let patient = Patient(name: "成员")
        let batch = ImportBatch(patientId: patient.id, sourceType: .file)
        let draft = CaptureDraft(
            patientId: patient.id,
            batchId: batch.id,
            documentIndex: 0,
            sourceType: .file
        )
        try batch.bindDraft(draft)
        let wrongPage = CapturePage(
            patientId: UUID(),
            batchId: batch.id,
            draftId: draft.id,
            sourceOrder: 0,
            pageIndex: 0,
            stagingRelativePath: "staging/wrong.jpg"
        )
        #expect(throws: CaptureGroupingError.wrongPatient) {
            try draft.bindPage(wrongPage)
        }
        #expect(draft.pages.isEmpty)
    }

    @Test("保存失败时 record、audit、draft 删除全部回滚")
    func saveFailure_rollsBackWholeCommit() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "妈妈", reportName: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .photo)
        let draft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [
                [DetectedNameCandidate(name: "王晓芸", confidence: 1, isReliable: true)]
            ]
        )
        context.insert(patient)
        context.insert(batch)
        try context.save()
        let record = MedicalRecord(
            patientId: patient.id,
            title: "失败提交",
            eventDate: Date(),
            sourceType: .photo
        )
        let service = CaptureCommitService(
            context: context,
            saveAction: { _ in throw InjectedCaptureError.save }
        )

        #expect(throws: CaptureCommitError.databaseSaveFailed) {
            try service.commit(
                CaptureCommitRequest(
                    draftId: draft.id,
                    expectedGeneration: draft.generation,
                    expectedOutcome: .match,
                    decision: .acceptedMatch,
                    assignedPatientId: patient.id,
                    record: record,
                    engineIdentifier: "vision"
                )
            )
        }
        #expect(try context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RecordAssignmentAudit>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CaptureDraft>()) == 1)
        #expect(batch.status == .staging)
    }

    @Test("OCR 导入不能绕过 CaptureCommitService 使用手动仓储")
    func recordRepository_rejectsImportedRecord() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        context.insert(patient)
        try context.save()
        let imported = MedicalRecord(
            patientId: patient.id,
            title: "导入记录",
            eventDate: Date(),
            sourceType: .file
        )
        #expect(throws: RecordRepositoryError.manualInsertOnly) {
            try RecordRepository(context: context).insert(imported)
        }
        #expect(try context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0)
    }

    @Test("手工仓储拒绝夹带上传附件或 OCR 证据")
    func recordRepository_rejectsCaptureEvidenceMarkedAsManual() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "成员")
        context.insert(patient)
        try context.save()

        let attachmentRecord = MedicalRecord(
            patientId: patient.id,
            title: "伪装手工附件",
            eventDate: Date(),
            sourceType: .manual,
            attachments: [
                Attachment(
                    patientId: patient.id,
                    fileName: "fixture.jpg",
                    kind: .image,
                    pageIndex: 0
                )
            ]
        )
        #expect(
            throws: RecordRepositoryError.manualRecordContainsCaptureEvidence
        ) {
            try RecordRepository(context: context).insert(attachmentRecord)
        }

        let ocrRecord = MedicalRecord(
            patientId: patient.id,
            title: "伪装手工 OCR",
            eventDate: Date(),
            sourceType: .manual,
            ocrText: "来自上传图片的文字",
            ocrEngineIdentifier: "fixture"
        )
        #expect(
            throws: RecordRepositoryError.manualRecordContainsCaptureEvidence
        ) {
            try RecordRepository(context: context).insert(ocrRecord)
        }
        #expect(try context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0)
    }

    @Test("可靠姓名不匹配时普通确认被硬拦截且无审计")
    func mismatch_normalAcceptanceIsBlocked() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "妈妈", reportName: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .photo)
        let draft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [
                [DetectedNameCandidate(name: "李明", confidence: 1, isReliable: true)]
            ]
        )
        context.insert(patient)
        context.insert(batch)
        try context.save()
        let record = MedicalRecord(
            patientId: patient.id,
            title: "错配",
            eventDate: Date(),
            sourceType: .photo
        )

        #expect(throws: CaptureCommitError.invalidDecision) {
            try CaptureCommitService(context: context).commit(
                CaptureCommitRequest(
                    draftId: draft.id,
                    expectedGeneration: draft.generation,
                    expectedOutcome: .mismatch,
                    decision: .acceptedMatch,
                    assignedPatientId: patient.id,
                    record: record,
                    engineIdentifier: "vision"
                )
            )
        }
        #expect(try context.fetchCount(FetchDescriptor<MedicalRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RecordAssignmentAudit>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CaptureDraft>()) == 1)
    }

    @Test("姓名识别错误覆盖必须留原因且只能保存到冻结成员")
    func mismatch_overrideRequiresReasonAndFrozenMember() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "妈妈", reportName: "王晓芸")
        let batch = ImportBatch(patientId: patient.id, sourceType: .file)
        let draft = try makeDraft(
            batch: batch,
            documentIndex: 0,
            pageCandidates: [
                [DetectedNameCandidate(name: "李明", confidence: 1, isReliable: true)]
            ]
        )
        context.insert(patient)
        context.insert(batch)
        try context.save()

        #expect(throws: CaptureCommitError.invalidDecision) {
            try CaptureCommitService(context: context).commit(
                CaptureCommitRequest(
                    draftId: draft.id,
                    expectedGeneration: draft.generation,
                    expectedOutcome: .mismatch,
                    decision: .acceptedAfterNameRecognitionOverride,
                    overrideReason: nil,
                    assignedPatientId: patient.id,
                    record: MedicalRecord(
                        patientId: patient.id,
                        title: "覆盖失败",
                        eventDate: Date(),
                        sourceType: .file
                    ),
                    engineIdentifier: "vision"
                )
            )
        }
        let audit = try CaptureCommitService(context: context).commit(
            CaptureCommitRequest(
                draftId: draft.id,
                expectedGeneration: draft.generation,
                expectedOutcome: .mismatch,
                decision: .acceptedAfterNameRecognitionOverride,
                overrideReason: "用户二次确认 OCR 姓名识别错误",
                assignedPatientId: patient.id,
                record: MedicalRecord(
                    patientId: patient.id,
                    title: "覆盖成功",
                    eventDate: Date(),
                    sourceType: .file
                ),
                engineIdentifier: "vision"
            )
        )
        #expect(audit.overrideReason == "用户二次确认 OCR 姓名识别错误")
    }

    @Test("提交边界再次拦截同成员精确 SHA 且不泄漏其他成员")
    func exactSHACommitGuardIsPatientScoped() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "虚构成员甲")
        let otherPatient = Patient(name: "虚构成员乙")
        let hash = String(repeating: "e", count: 64)
        let otherRecordID = UUID()
        let otherRecord = MedicalRecord(
            id: otherRecordID,
            patientId: otherPatient.id,
            title: "乙的同哈希虚构记录",
            eventDate: Date(),
            sourceType: .photo,
            attachments: [
                try verifiedAttachment(
                    patientID: otherPatient.id,
                    recordID: otherRecordID,
                    sha256: hash
                )
            ]
        )
        context.insert(patient)
        context.insert(otherPatient)
        context.insert(otherRecord)
        try context.save()

        let firstBatch = ImportBatch(patientId: patient.id, sourceType: .photo)
        let firstDraft = try makeDraft(
            batch: firstBatch,
            documentIndex: 0,
            pageCandidates: [[]]
        )
        context.insert(firstBatch)
        try context.save()
        let firstRecordID = UUID()
        _ = try CaptureCommitService(context: context).commit(
            CaptureCommitRequest(
                draftId: firstDraft.id,
                expectedGeneration: firstDraft.generation,
                expectedOutcome: .noEvidence,
                decision: .acceptedWithoutNameEvidence,
                assignedPatientId: patient.id,
                record: MedicalRecord(
                    id: firstRecordID,
                    patientId: patient.id,
                    title: "甲第一次添加",
                    eventDate: Date(),
                    sourceType: .photo,
                    attachments: [
                        try verifiedAttachment(
                            patientID: patient.id,
                            recordID: firstRecordID,
                            sha256: hash
                        )
                    ]
                ),
                engineIdentifier: "vision"
            )
        )

        let secondBatch = ImportBatch(patientId: patient.id, sourceType: .photo)
        let secondDraft = try makeDraft(
            batch: secondBatch,
            documentIndex: 0,
            pageCandidates: [[]]
        )
        context.insert(secondBatch)
        try context.save()
        let secondRecordID = UUID()
        #expect(throws: CaptureCommitError.duplicateAttachmentSHA) {
            try CaptureCommitService(context: context).commit(
                CaptureCommitRequest(
                    draftId: secondDraft.id,
                    expectedGeneration: secondDraft.generation,
                    expectedOutcome: .noEvidence,
                    decision: .acceptedWithoutNameEvidence,
                    assignedPatientId: patient.id,
                    record: MedicalRecord(
                        id: secondRecordID,
                        patientId: patient.id,
                        title: "甲重复添加",
                        eventDate: Date(),
                        sourceType: .photo,
                        attachments: [
                            try verifiedAttachment(
                                patientID: patient.id,
                                recordID: secondRecordID,
                                sha256: hash
                            )
                        ]
                    ),
                    engineIdentifier: "vision"
                )
            )
        }
        #expect(
            try context.fetchCount(FetchDescriptor<MedicalRecord>()) == 2
        )
    }

    private func verifiedAttachment(
        patientID: UUID,
        recordID: UUID,
        sha256: String
    ) throws -> Attachment {
        let attachmentID = UUID()
        return try Attachment.verified(
            id: attachmentID,
            patientId: patientID,
            recordId: recordID,
            originalRelativePath:
                "members/\(patientID.uuidString)/records/\(recordID.uuidString)"
                + "/attachments/\(attachmentID.uuidString)/original.jpg",
            displayFileName: "虚构报告.jpg",
            kind: .image,
            pageIndex: 0,
            uniformTypeIdentifier: "public.jpeg",
            byteCount: 128,
            sha256: sha256,
            importSource: .fixture,
            pixelWidth: 1_200,
            pixelHeight: 1_600
        )
    }

    private func makeDraft(
        batch: ImportBatch,
        documentIndex: Int,
        pageCandidates: [[DetectedNameCandidate]]
    ) throws -> CaptureDraft {
        let draft = CaptureDraft(
            patientId: batch.patientId,
            batchId: batch.id,
            documentIndex: documentIndex,
            sourceType: batch.sourceType
        )
        try batch.bindDraft(draft)
        var pages: [CapturePage] = []
        for index in pageCandidates.indices {
            let page = CapturePage(
                patientId: batch.patientId,
                batchId: batch.id,
                draftId: draft.id,
                sourceOrder: index,
                pageIndex: index,
                stagingRelativePath: "staging/\(documentIndex)-\(index).jpg"
            )
            try draft.bindPage(page)
            pages.append(page)
        }
        let generation = draft.generation
        for (index, page) in pages.enumerated() {
            let candidates = pageCandidates[index]
            try page.applyOCR(
                generation: generation,
                status: candidates.isEmpty ? .noEvidence : .recognized,
                text: candidates.isEmpty ? "续页无姓名" : "姓名 \(candidates[0].name)",
                detectedNameCandidates: candidates
            )
        }
        return draft
    }
}

private enum InjectedCaptureError: Error {
    case save
}
