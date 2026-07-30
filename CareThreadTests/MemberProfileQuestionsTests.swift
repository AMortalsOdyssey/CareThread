import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
@Suite("Member profile and persistent visit questions")
struct MemberProfileQuestionsTests {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    @Test("成员称呼不能为空")
    func emptyDisplayNameRejected() {
        #expect(throws: PatientProfileValidationError.displayNameRequired) {
            try PatientProfilePolicy.validateIdentity(
                displayName: " \n",
                reportName: nil,
                aliases: [],
                birthDate: nil,
                gender: nil,
                now: now
            )
        }
    }

    @Test("64 字符成员称呼是闭区间上界")
    func displayNameBoundaryAccepted() throws {
        try PatientProfilePolicy.validateIdentity(
            displayName: String(repeating: "名", count: 64),
            reportName: String(repeating: "姓", count: 64),
            aliases: [],
            birthDate: nil,
            gender: nil,
            now: now
        )
    }

    @Test("65 字符成员称呼被拒绝")
    func displayNameTooLongRejected() {
        #expect(throws: PatientProfileValidationError.displayNameTooLong) {
            try PatientProfilePolicy.validateIdentity(
                displayName: String(repeating: "名", count: 65),
                reportName: nil,
                aliases: [],
                birthDate: nil,
                gender: nil,
                now: now
            )
        }
    }

    @Test("姓名别名允许 20 个且逐项保留")
    func aliasCountBoundaryAccepted() throws {
        try PatientProfilePolicy.validateIdentity(
            displayName: "虚构成员",
            reportName: "测试姓名",
            aliases: (0..<20).map { "别名\($0)" },
            birthDate: nil,
            gender: nil,
            now: now
        )
    }

    @Test("规范化后重复的姓名别名被拒绝")
    func normalizedDuplicateAliasRejected() {
        #expect(throws: PatientProfileValidationError.duplicateAlias) {
            try PatientProfilePolicy.validateIdentity(
                displayName: "虚构成员",
                reportName: nil,
                aliases: ["ＷＡＮＧ", "wang"],
                birthDate: nil,
                gender: nil,
                now: now
            )
        }
    }

    @Test("未来出生日期被拒绝")
    func futureBirthDateRejected() {
        #expect(throws: PatientProfileValidationError.birthDateInFuture) {
            try PatientProfilePolicy.validateIdentity(
                displayName: "虚构成员",
                reportName: nil,
                aliases: [],
                birthDate: now.addingTimeInterval(86_400),
                gender: nil,
                now: now
            )
        }
    }

    @Test("主要情况最多 64 项")
    func healthListLimitRejected() {
        #expect(throws: PatientProfileValidationError.tooManyConditions) {
            try PatientProfilePolicy.validateHealthLists(
                conditions: (0...64).map { "虚构情况\($0)" },
                allergies: [],
                histories: [],
                now: now
            )
        }
    }

    @Test("病史年份越界被拒绝")
    func historyYearRejected() {
        #expect(throws: PatientProfileValidationError.historyYearOutOfRange) {
            try PatientProfilePolicy.validateHealthLists(
                conditions: [],
                allergies: [],
                histories: [HistoryItem(year: 1899, text: "虚构病史")],
                now: now
            )
        }
    }

    @Test("空问题被拒绝")
    func emptyQuestionRejected() {
        #expect(throws: PatientProfileValidationError.questionRequired) {
            try PatientProfilePolicy.validateQuestions(
                [CareQuestion(text: " ")]
            )
        }
    }

    @Test("已回答问题必须有回答或笔记")
    func answeredNeedsContent() {
        #expect(
            throws:
                PatientProfileValidationError.answeredQuestionNeedsAnswerOrNote
        ) {
            try PatientProfilePolicy.validateQuestions(
                [CareQuestion(text: "虚构问题", status: .answered)]
            )
        }
    }

    @Test("待问问题允许尚无回答")
    func pendingQuestionAccepted() throws {
        try PatientProfilePolicy.validateQuestions(
            [CareQuestion(text: "虚构问题", status: .pending)]
        )
    }

    @Test("无效创建不产生成员")
    func invalidMemberCreationHasNoSideEffects() throws {
        let container = try TestSupport.container()
        #expect(throws: MemberServiceError.invalidProfile(.displayNameRequired)) {
            try MemberService(
                context: container.mainContext,
                vaultProvisioner: NoopMemberVaultProvisioner(),
                selectionStore: InMemorySelectedMemberStore()
            ).createMember(displayName: "")
        }
        #expect(
            try container.mainContext.fetchCount(
                FetchDescriptor<Patient>()
            ) == 0
        )
    }

    @Test("成员切换只改变选择")
    func selectionChangesOnlySelectedID() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = Patient(displayName: "虚构甲")
        let second = Patient(displayName: "虚构乙")
        context.insert(first)
        context.insert(second)
        try context.save()
        let store = InMemorySelectedMemberStore()
        let service = MemberService(
            context: context,
            vaultProvisioner: NoopMemberVaultProvisioner(),
            selectionStore: store
        )
        try service.selectMember(id: second.id)
        #expect(store.selectedPatientId == second.id)
        #expect(try context.fetchCount(FetchDescriptor<Patient>()) == 2)
    }

    @Test("删除当前成员会清除其资料并安全切换且保留其他成员")
    func deletingSelectedMemberIsTenantScoped() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = Patient(
            displayName: "虚构甲",
            careQuestions: [CareQuestion(text: "仅属于甲")]
        )
        let second = Patient(
            displayName: "虚构乙",
            careQuestions: [CareQuestion(text: "仅属于乙")]
        )
        context.insert(first)
        context.insert(second)
        context.insert(
            MedicalRecord(
                patientId: first.id,
                title: "甲的虚构记录",
                eventDate: now
            )
        )
        context.insert(
            MedicalRecord(
                patientId: second.id,
                title: "乙的虚构记录",
                eventDate: now
            )
        )
        try context.save()
        let selection = InMemorySelectedMemberStore()
        selection.selectedPatientId = first.id
        let vault = TrackingMemberVaultProvisioner()

        let selectedAfter = try MemberService(
            context: context,
            vaultProvisioner: vault,
            selectionStore: selection
        ).deleteMember(id: first.id)

        #expect(selectedAfter == second.id)
        #expect(selection.selectedPatientId == second.id)
        #expect(try context.fetch(FetchDescriptor<Patient>()).map(\.id) == [second.id])
        #expect(
            try context.fetch(FetchDescriptor<MedicalRecord>())
                .map(\.patientId) == [second.id]
        )
        #expect(
            try context.fetch(FetchDescriptor<Patient>()).first?
                .careQuestions.map(\.text) == ["仅属于乙"]
        )
        #expect(vault.deletedIDs == [first.id])
    }

    @Test("删除未选中成员保持当前选择")
    func deletingUnselectedMemberPreservesSelection() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let selected = Patient(displayName: "虚构当前")
        let other = Patient(displayName: "虚构待删")
        context.insert(selected)
        context.insert(other)
        try context.save()
        let selection = InMemorySelectedMemberStore()
        selection.selectedPatientId = selected.id

        let selectedAfter = try MemberService(
            context: context,
            vaultProvisioner: NoopMemberVaultProvisioner(),
            selectionStore: selection
        ).deleteMember(id: other.id)

        #expect(selectedAfter == selected.id)
        #expect(selection.selectedPatientId == selected.id)
        #expect(try context.fetch(FetchDescriptor<Patient>()).map(\.id) == [selected.id])
    }

    @Test("删除捕获来源成员保留归属成员审计并清理旧版 nil 归属行")
    func deletingCapturedMemberPreservesAssignedOwnerAudit() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let captured = Patient(displayName: "虚构捕获成员")
        let assigned = Patient(displayName: "虚构归属成员")
        let capturedRecord = MedicalRecord(
            patientId: captured.id,
            title: "旧版虚构记录",
            eventDate: now
        )
        let assignedRecord = MedicalRecord(
            patientId: assigned.id,
            title: "切换后虚构记录",
            eventDate: now
        )
        let switchedAuditID = UUID()
        context.insert(captured)
        context.insert(assigned)
        context.insert(capturedRecord)
        context.insert(assignedRecord)
        context.insert(
            RecordAssignmentAudit(
                id: switchedAuditID,
                capturedForPatientId: captured.id,
                assignedPatientId: assigned.id,
                recordId: assignedRecord.id,
                detectedName: "虚构姓名",
                outcome: .mismatch,
                decision: .switchedMember,
                engineIdentifier: "test.offline"
            )
        )
        context.insert(
            RecordAssignmentAudit(
                capturedForPatientId: captured.id,
                assignedPatientId: nil,
                recordId: capturedRecord.id,
                detectedName: nil,
                outcome: .noEvidence,
                decision: .acceptedWithoutNameEvidence,
                engineIdentifier: "legacy.test"
            )
        )
        try context.save()
        let selection = InMemorySelectedMemberStore()
        selection.selectedPatientId = assigned.id
        let service = MemberService(
            context: context,
            vaultProvisioner: NoopMemberVaultProvisioner(),
            selectionStore: selection
        )

        _ = try service.deleteMember(id: captured.id)

        let remainingAudits = try context.fetch(
            FetchDescriptor<RecordAssignmentAudit>()
        )
        #expect(remainingAudits.map(\.id) == [switchedAuditID])
        #expect(remainingAudits.first?.assignedPatientId == assigned.id)
        #expect(remainingAudits.first?.capturedForPatientId == captured.id)

        _ = try service.deleteMember(id: assigned.id)
        #expect(
            try context.fetchCount(FetchDescriptor<RecordAssignmentAudit>()) == 0
        )
    }

    @Test("删除保存失败回滚资料且不删除 Vault 或改变选择")
    func failedDeletionRollsBackWithoutVaultSideEffect() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构成员")
        context.insert(patient)
        try context.save()
        let selection = InMemorySelectedMemberStore()
        selection.selectedPatientId = patient.id
        let vault = TrackingMemberVaultProvisioner()

        #expect(throws: MemberServiceError.databaseSaveFailed) {
            try MemberService(
                context: context,
                vaultProvisioner: vault,
                selectionStore: selection,
                saveAction: { _ in throw MemberDeletionTestError.save }
            ).deleteMember(id: patient.id)
        }

        #expect(try context.fetchCount(FetchDescriptor<Patient>()) == 1)
        #expect(selection.selectedPatientId == patient.id)
        #expect(vault.deletedIDs.isEmpty)
    }

    @Test("不存在的成员不能被选中")
    func missingMemberCannotBeSelected() throws {
        let container = try TestSupport.container()
        let store = InMemorySelectedMemberStore()
        #expect(throws: MemberServiceError.memberNotFound) {
            try MemberService(
                context: container.mainContext,
                vaultProvisioner: NoopMemberVaultProvisioner(),
                selectionStore: store
            ).selectMember(id: UUID())
        }
        #expect(store.selectedPatientId == nil)
    }

    @Test("全字段编辑通过 CAS 一次提交")
    func fullProfileEditPersistsAllBusinessFields() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构旧称")
        context.insert(patient)
        try context.save()
        var content = patient.editableContent()
        content.displayName = "虚构新称"
        content.reportName = "测试姓名"
        content.aliases = ["测试别名"]
        content.birthDate = now.addingTimeInterval(-10_000_000)
        content.gender = "未说明"
        content.conditions = ["虚构情况"]
        content.allergies = ["虚构过敏"]
        content.histories = [HistoryItem(year: 2020, text: "虚构病史")]

        let revision = try PatientProfileService(
            context: context,
            now: { now }
        ).save(patient, content: content, expectedRevision: 0)

        #expect(patient.displayName == "虚构新称")
        #expect(patient.reportName == "测试姓名")
        #expect(patient.aliases == ["测试别名"])
        #expect(patient.conditions == ["虚构情况"])
        #expect(patient.allergies == ["虚构过敏"])
        #expect(patient.histories.map(\.text) == ["虚构病史"])
        #expect(revision.changedFieldKeys.contains("histories"))
        #expect(patient.contentRevision == 1)
    }

    @Test("过期 expectedRevision 被 CAS 拒绝")
    func staleExpectedRevisionRejected() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构成员")
        context.insert(patient)
        try context.save()
        let service = PatientProfileService(context: context)
        var first = patient.editableContent()
        first.displayName = "第一次"
        _ = try service.save(patient, content: first, expectedRevision: 0)
        var stale = patient.editableContent()
        stale.displayName = "过期覆盖"
        #expect(
            throws:
                ContentRevisionServiceError.revisionConflict(
                    expected: 0,
                    actual: 1
                )
        ) {
            try service.save(patient, content: stale, expectedRevision: 0)
        }
        #expect(patient.displayName == "第一次")
    }

    @Test("添加问题后可由新上下文读取")
    func questionPersistsAcrossContextReopen() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构成员")
        context.insert(patient)
        try context.save()
        _ = try PatientProfileService(
            context: context,
            now: { now }
        ).addQuestion(
            to: patient,
            text: "下次要带哪些虚构资料？",
            note: "准备虚构材料",
            expectedRevision: 0
        )

        let second = ModelContext(container)
        let id = patient.id
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let reopened = try #require(second.fetch(descriptor).first)
        #expect(reopened.careQuestions.count == 1)
        #expect(reopened.careQuestions.first?.note == "准备虚构材料")
    }

    @Test("问题状态回答和笔记可编辑且稳定 UUID")
    func questionStatusAnswerAndNoteUpdate() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let question = CareQuestion(text: "虚构问题", createdAt: now)
        let patient = Patient(
            displayName: "虚构成员",
            careQuestions: [question]
        )
        context.insert(patient)
        try context.save()

        _ = try PatientProfileService(
            context: context,
            now: { now.addingTimeInterval(30) }
        ).updateQuestion(
            on: patient,
            id: question.id,
            text: "虚构问题已更正",
            answer: "虚构回答",
            note: "虚构就诊笔记",
            status: .answered,
            expectedRevision: 0
        )

        #expect(patient.careQuestions.first?.id == question.id)
        #expect(patient.careQuestions.first?.status == .answered)
        #expect(patient.careQuestions.first?.answer == "虚构回答")
        #expect(patient.careQuestions.first?.note == "虚构就诊笔记")
    }

    @Test("删除问题仅删除目标 UUID")
    func removeQuestionDeletesOnlyTarget() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = CareQuestion(text: "问题一")
        let second = CareQuestion(text: "问题二")
        let patient = Patient(
            displayName: "虚构成员",
            careQuestions: [first, second]
        )
        context.insert(patient)
        try context.save()
        _ = try PatientProfileService(context: context).removeQuestion(
            from: patient,
            id: first.id,
            expectedRevision: 0
        )
        #expect(patient.careQuestions.map(\.id) == [second.id])
    }

    @Test("撤销问题变更恢复前值并追加 undo 修订")
    func questionEditUndoRestoresPreviousValue() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构成员")
        context.insert(patient)
        try context.save()
        let service = PatientProfileService(context: context)
        _ = try service.addQuestion(
            to: patient,
            text: "虚构问题",
            expectedRevision: 0
        )
        _ = try service.undoLast(patient, expectedRevision: 1)
        #expect(patient.careQuestions.isEmpty)
        #expect(patient.contentRevision == 2)
        #expect(try service.history(for: patient).first?.source == .undo)
    }

    @Test("摘要编辑待问列表保留已有 UUID和已回答问题")
    func replacePendingPreservesStableIDsAndAnswered() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let pending = CareQuestion(text: "原待问", createdAt: now)
        let answered = CareQuestion(
            text: "已回答",
            status: .answered,
            answer: "虚构回答",
            createdAt: now.addingTimeInterval(-10)
        )
        let patient = Patient(
            displayName: "虚构成员",
            careQuestions: [pending, answered]
        )
        context.insert(patient)
        try context.save()
        _ = try PatientProfileService(
            context: context,
            now: { now.addingTimeInterval(50) }
        ).replacePendingQuestions(
            on: patient,
            texts: ["更新后的待问", "新增待问"],
            expectedRevision: 0
        )
        #expect(
            patient.careQuestions.first(where: {
                $0.status == .pending
            })?.id == pending.id
        )
        #expect(
            patient.careQuestions.contains(where: {
                $0.id == answered.id && $0.answer == "虚构回答"
            })
        )
        #expect(patient.careQuestions.count == 3)
    }

    @Test("两个成员的问题数据严格隔离")
    func questionsAreMemberScoped() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = Patient(displayName: "虚构甲")
        let second = Patient(displayName: "虚构乙")
        context.insert(first)
        context.insert(second)
        try context.save()
        _ = try PatientProfileService(context: context).addQuestion(
            to: first,
            text: "只属于甲的问题",
            expectedRevision: 0
        )
        #expect(first.careQuestions.map(\.text) == ["只属于甲的问题"])
        #expect(second.careQuestions.isEmpty)
    }

    @Test("旧 PatientEditableContent 无 careQuestions 时默认空数组")
    func legacyEditableContentDecodesWithoutQuestions() throws {
        let payload = Data(
            """
            {
              "displayName":"虚构旧成员",
              "reportName":null,
              "aliases":[],
              "birthDate":null,
              "gender":null,
              "conditions":[],
              "allergies":[],
              "histories":[],
              "updatedAt":0
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let content = try decoder.decode(
            PatientEditableContent.self,
            from: payload
        )
        #expect(content.careQuestions.isEmpty)
    }

    @Test("Nearby Patient payload 自动携带问题并保持 UUID")
    func nearbySnapshotCarriesQuestions() throws {
        let question = CareQuestion(
            text: "虚构迁移问题",
            note: "虚构迁移笔记",
            createdAt: now
        )
        let patient = Patient(
            displayName: "虚构成员",
            careQuestions: [question]
        )
        let snapshot = NearbySyncSnapshotFactory.make(patient)
        #expect(
            snapshot.payload.patient?.editable.careQuestions.first?.id
                == question.id
        )
        #expect(
            snapshot.payload.patient?.editable.careQuestions.first?.note
                == "虚构迁移笔记"
        )
    }

    @Test("摘要加载默认读取持久化待问并排除已回答")
    func briefLoaderUsesPersistentPendingQuestions() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(
            displayName: "虚构成员",
            careQuestions: [
                CareQuestion(text: "待问问题", createdAt: now),
                CareQuestion(
                    text: "已回答问题",
                    status: .answered,
                    answer: "虚构回答",
                    createdAt: now
                )
            ]
        )
        context.insert(patient)
        try context.save()
        let input = try M7BriefDataLoader(context: context).load(
            patientID: patient.id
        )
        #expect(input.questions == ["待问问题"])
    }
}

private enum MemberDeletionTestError: Error {
    case save
}

private final class TrackingMemberVaultProvisioner: MemberVaultProvisioning {
    private(set) var deletedIDs: [UUID] = []

    func provisionVault(for patientId: UUID) throws {}
    func rollbackVault(for patientId: UUID) {}

    func deleteVault(for patientId: UUID) {
        deletedIDs.append(patientId)
    }
}
