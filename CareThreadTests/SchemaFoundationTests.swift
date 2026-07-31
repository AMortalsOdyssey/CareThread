import Foundation
import SwiftData
import Testing
@testable import CareThread

// Xcode 26.6 起 Swift Testing 自带 Attachment 类型，与 App 模型撞名；本文件内统一指回 App 模型。
private typealias Attachment = CareThread.Attachment

@MainActor
struct SchemaFoundationTests {
    @Test("成员数量 19 时允许新增")
    func memberLimit_allowsTwentiethMember() throws {
        try MemberLimitPolicy.validateAddition(existingCount: 19)
        #expect(MemberLimitPolicy.maximumMembers == 20)
    }

    @Test("成员数量达到 20 时拒绝新增")
    func memberLimit_rejectsTwentyFirstMember() {
        #expect(throws: MemberLimitPolicyError.maximumReached(limit: 20)) {
            try MemberLimitPolicy.validateAddition(existingCount: 20)
        }
    }

    @Test("成员数量负数视为数据错误")
    func memberLimit_rejectsNegativeCount() {
        #expect(throws: MemberLimitPolicyError.invalidExistingCount(-1)) {
            try MemberLimitPolicy.validateAddition(existingCount: -1)
        }
    }

    @Test("成员称呼、报告姓名和别名生成稳定去重匹配值")
    func patientIdentity_normalizesAliases() {
        let patient = Patient(
            name: "妈妈",
            reportName: " 王 晓芸 ",
            aliases: ["王晓芸", "ＷＡＮＧ　ＸＩＡＯＹＵＮ"]
        )

        #expect(patient.displayName == "妈妈")
        #expect(patient.reportName == "王 晓芸")
        #expect(patient.normalizedAliases == ["王晓芸", "wangxiaoyun"])
        #expect(patient.normalizedSearchText.contains("|王晓芸|"))
    }

    @Test("旧 name 和 birthday 门面保持兼容")
    func patient_legacyFacadeRoundTrips() throws {
        let birthday = Date(timeIntervalSince1970: 1_000)
        let patient = Patient(name: "成员 A", birthday: birthday)
        #expect(patient.name == "成员 A")
        #expect(patient.birthDate == birthday)

        var edited = patient.editableContent()
        edited.displayName = "成员 B"
        try patient.applyEditableContent(edited)
        #expect(patient.displayName == "成员 B")
    }

    @Test("患者结构化数组使用版本化 JSON 字节往返")
    func patientPayload_roundTripsWithoutTransformableArrays() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(
            name: "虚构成员",
            conditions: ["虚构病种"],
            allergies: ["虚构过敏"],
            histories: [HistoryItem(year: 2026, text: "虚构历史")]
        )
        context.insert(patient)
        try context.save()
        context.rollback()

        let fetched = try #require(context.fetch(FetchDescriptor<Patient>()).first)
        #expect(fetched.conditions == ["虚构病种"])
        #expect(fetched.allergies == ["虚构过敏"])
        #expect(fetched.histories.map(\.year) == [2026])
        #expect(!fetched.conditionsPayload.isEmpty)
        let json = try #require(
            try JSONSerialization.jsonObject(with: fetched.conditionsPayload) as? [String: Any]
        )
        #expect(json["schemaVersion"] as? Int == ModelPayload.currentSchemaVersion)
    }

    @Test("记录筛选字段规范化且保留事件日期语义")
    func medicalRecord_filterFieldsAreStable() {
        let record = MedicalRecord(
            patientId: UUID(),
            type: .outpatient,
            title: "虚构门诊",
            eventDate: Date(timeIntervalSince1970: 2_000),
            eventDatePrecision: .exactTime,
            eventTimezoneIdentifier: "Asia/Shanghai",
            hospital: " 测试医院 ",
            doctor: " 张 医生 ",
            primaryDisease: " 虚构病种 ",
            diseaseTags: ["虚构病种"],
            ageAtEvent: 42
        )

        #expect(record.typeRawValue == RecordType.outpatient.rawValue)
        #expect(record.eventDatePrecision == .exactTime)
        #expect(record.eventTimezoneIdentifier == "Asia/Shanghai")
        #expect(record.normalizedHospital == "测试医院")
        #expect(record.normalizedDoctor == "张医生")
        #expect(record.normalizedPrimaryDisease == "虚构病种")
        #expect(record.diseaseTags == ["虚构病种"])
        #expect(record.ageAtEvent == 42)
    }

    @Test("检验指标拆为可查询实体并继承成员归属")
    func labMeasurement_isQueryableAndScoped() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patientId = UUID()
        let record = MedicalRecord(
            patientId: patientId,
            type: .lab,
            title: "虚构检验",
            eventDate: Date(timeIntervalSince1970: 3_000),
            labItems: [
                LabItem(name: "TSH", value: 1.2, unit: "mIU/L", flag: .none)
            ]
        )
        context.insert(record)
        try context.save()

        let measurement = try #require(context.fetch(FetchDescriptor<LabMeasurement>()).first)
        #expect(measurement.patientId == patientId)
        #expect(measurement.recordId == record.id)
        #expect(measurement.normalizedName == "tsh")
        #expect(record.labItems.first?.value == 1.2)
    }

    @Test("所有新增业务实体必须显式保留成员归属")
    func newEntities_keepPatientScope() {
        let patientId = UUID()
        let recordId = UUID()
        let attachment = Attachment(
            patientId: patientId,
            fileName: "vault/member/original.jpg",
            kind: .image,
            pageIndex: 0
        )
        let measurement = LabMeasurement(
            patientId: patientId,
            recordId: recordId,
            displayName: "虚构指标",
            numericValue: 1,
            eventDate: Date()
        )
        let tag = RecordTag(
            patientId: patientId,
            recordId: recordId,
            kind: .disease,
            displayValue: "虚构病种"
        )
        let audit = RecordAssignmentAudit(
            capturedForPatientId: patientId,
            assignedPatientId: patientId,
            detectedName: "虚构姓名",
            outcome: .match,
            decision: .acceptedMatch,
            engineIdentifier: "vision"
        )
        let reminder = try! ReminderSchedule(
            patientId: patientId,
            kind: .custom,
            title: "虚构提醒",
            schedule: ReminderRule(kind: .once, startAt: Date())
        )

        #expect(attachment.patientId == patientId)
        #expect(measurement.patientId == patientId)
        #expect(tag.patientId == patientId)
        #expect(audit.capturedForPatientId == patientId)
        #expect(reminder.patientId == patientId)
    }

    @Test("跨成员作用域校验拒绝不一致 UUID")
    func scopeValidator_rejectsMismatch() {
        let expected = UUID()
        let actual = UUID()
        #expect(throws: PatientScopeError.mismatch(expected: expected, actual: actual)) {
            try PatientScopeValidator.require(actual, equals: expected)
        }
    }

    @Test("姓名不匹配不能静默添加")
    func assignmentPolicy_mismatchRequiresExplicitPath() {
        #expect(throws: RecordAssignmentPolicyError.invalidDecision(
            outcome: .mismatch,
            decision: .acceptedMatch
        )) {
            try RecordAssignmentPolicy.validate(
                outcome: .mismatch,
                decision: .acceptedMatch,
                overrideReason: nil
            )
        }
    }

    @Test("姓名识别错误覆盖必须填写明确原因")
    func assignmentPolicy_overrideRequiresReason() throws {
        #expect(throws: RecordAssignmentPolicyError.overrideReasonRequired) {
            try RecordAssignmentPolicy.validate(
                outcome: .mismatch,
                decision: .acceptedAfterNameRecognitionOverride,
                overrideReason: " "
            )
        }
        try RecordAssignmentPolicy.validate(
            outcome: .mismatch,
            decision: .acceptedAfterNameRecognitionOverride,
            overrideReason: "用户二次确认姓名识别错误"
        )
    }

    @Test("归属审计保留捕获目标、检测结果和引擎版本")
    func assignmentAudit_preservesEvidence() {
        let target = UUID()
        let assigned = UUID()
        let audit = RecordAssignmentAudit(
            capturedForPatientId: target,
            assignedPatientId: assigned,
            detectedName: " 王晓芸 ",
            outcome: .mismatch,
            decision: .switchedMember,
            engineIdentifier: "vision",
            engineVersion: "18.6"
        )

        #expect(audit.capturedForPatientId == target)
        #expect(audit.assignedPatientId == assigned)
        #expect(audit.detectedName == "王晓芸")
        #expect(audit.normalizedDetectedName == "王晓芸")
        #expect(audit.outcome == .mismatch)
        #expect(audit.decision == .switchedMember)
        #expect(audit.engineVersion == "18.6")
    }

    @Test("提醒业务规则与 Apple 适配标识分离")
    func reminderSchedule_separatesBusinessRuleFromAdapters() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        let rule = ReminderRule(
            kind: .weekly,
            startAt: start,
            timezoneIdentifier: "Asia/Shanghai",
            hour: 8,
            minute: 30,
            isoWeekdays: [1, 3, 5]
        )
        let reminder = try ReminderSchedule(
            patientId: UUID(),
            kind: .medication,
            title: "虚构服药提醒",
            schedule: rule
        )
        let binding = AppleReminderBinding(
            patientId: reminder.patientId,
            reminderId: reminder.id,
            destination: .localNotification,
            localNotificationIdentifier: "un.adapter.id",
            calendarEventIdentifier: nil
        )

        #expect(reminder.schedule == rule)
        #expect(reminder.schedule.schemaVersion == ReminderRule.currentSchemaVersion)
        #expect(binding.localNotificationIdentifier == "un.adapter.id")
        #expect(binding.calendarEventIdentifier == nil)
    }

    @Test("V1 schema 明确包含全部 15 个模型")
    func schemaV1_containsAllEntities() {
        let names = Set(CareThreadSchemaV1.models.map { String(describing: $0) })
        #expect(CareThreadSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(names.count == 15)
        #expect(names.contains("Patient"))
        #expect(names.contains("LabMeasurement"))
        #expect(names.contains("RecordAssignmentAudit"))
        #expect(names.contains("ReminderSchedule"))
        #expect(names.contains("ImportBatch"))
        #expect(names.contains("CapturePage"))
        #expect(names.contains("AppleReminderBinding"))
        #expect(names.contains("ContentRevision"))
    }
}
