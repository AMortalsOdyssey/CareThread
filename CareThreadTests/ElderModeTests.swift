import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import CareThread

@MainActor
struct ElderModeTests {
    @Test("标准版 token 保持原尺寸")
    func standardTokens() {
        let value = ElderTypographyValues.resolve(mode: .standard)
        #expect(value.headline == 17)
        #expect(value.body == 17)
        #expect(value.primaryButtonHeight == 50)
        #expect(value.listRowHeight == 52)
    }

    @Test("老人版 token 覆盖标题正文与元信息")
    func elderTypographyTokens() {
        let value = ElderTypographyValues.resolve(mode: .elder)
        #expect(value.display == 40)
        #expect(value.headline == 22)
        #expect(value.body == 20)
        #expect(value.footnote == 16)
    }

    @Test("老人版按钮行高与触达满足规范")
    func elderComponentSizeTokens() {
        let value = ElderTypographyValues.resolve(mode: .elder)
        #expect(value.primaryButtonHeight == 60)
        #expect(value.listRowHeight == 64)
        #expect(value.touchTarget == 56)
        #expect(CT.Size.elderChoiceButtonHeight == 88)
    }

    @Test("老人版应用内三档字号单调且正文不低于20")
    func elderFontScaleTokens() {
        let standard = ElderTypographyValues.resolve(
            mode: .elder,
            elderScale: .standard
        )
        let larger = ElderTypographyValues.resolve(
            mode: .elder,
            elderScale: .larger
        )
        let largest = ElderTypographyValues.resolve(
            mode: .elder,
            elderScale: .largest
        )
        #expect(standard.body >= 20)
        #expect(standard.body < larger.body)
        #expect(larger.body < largest.body)
    }

    @Test("系统动态字号在 AX2 封顶")
    func dynamicTypeCapsAtAX2() {
        #expect(
            ElderDynamicTypePolicy.capped(.accessibility5)
                == .accessibility2
        )
        #expect(
            ElderDynamicTypePolicy.capped(.accessibility1)
                == .accessibility1
        )
    }

    @Test("显示模式写入并从 UserDefaults 重启读取")
    func displayModePersists() throws {
        let suite = try #require(
            UserDefaults(
                suiteName: "CareThread.ElderModeTests.\(UUID().uuidString)"
            )
        )
        let store = ElderDisplayModeStore(defaults: suite)
        store.storedMode = .elder
        let reopened = ElderDisplayModeStore(defaults: suite)
        #expect(reopened.storedMode == .elder)
    }

    @Test("launch override 优先于已存模式")
    func launchOverrideWins() throws {
        let suite = try #require(
            UserDefaults(
                suiteName: "CareThread.ElderOverride.\(UUID().uuidString)"
            )
        )
        let store = ElderDisplayModeStore(defaults: suite)
        store.storedMode = .elder
        #expect(store.effectiveMode(launchOverride: .standard) == .standard)
        #expect(store.storedMode == .elder)
    }

    @Test("切换显示模式不改任何 SwiftData 实体")
    func switchingModeDoesNotMutateData() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        try SeedService.seedDemo(into: context)
        let before = try entityCounts(context)
        let suite = try #require(
            UserDefaults(
                suiteName: "CareThread.ElderInvariant.\(UUID().uuidString)"
            )
        )
        let store = ElderDisplayModeStore(defaults: suite)
        store.storedMode = .elder
        store.storedMode = .standard
        let after = try entityCounts(context)
        #expect(before == after)
    }

    @Test("检查报告保留机器识别的影像精确类型")
    func combinedExaminationKeepsImaging() {
        #expect(
            ElderCaptureTypePolicy.resolvedType(
                choice: .examination,
                machineType: .imaging
            ) == .imaging
        )
    }

    @Test("检查报告保留机器识别的病理精确类型")
    func combinedExaminationKeepsPathology() {
        #expect(
            ElderCaptureTypePolicy.resolvedType(
                choice: .examination,
                machineType: .pathology
            ) == .pathology
        )
    }

    @Test("老人选择化验单可明确归为检验")
    func explicitLabChoice() {
        #expect(
            ElderCaptureTypePolicy.resolvedType(
                choice: .lab,
                machineType: .other
            ) == .lab
        )
    }

    @Test("老人版不显示标准版草稿续录入口")
    func elderHidesStandardDraftResume() {
        #expect(
            !ElderDraftVisibilityPolicy
                .shouldShowStandardDraftResume(in: .elder)
        )
        #expect(
            ElderDraftVisibilityPolicy
                .shouldShowStandardDraftResume(in: .standard)
        )
    }

    @Test("老人版用药通知使用直白命名空间")
    func elderMedicationNotificationCopy() {
        let value = ElderNotificationCopyBuilder.medication(
            name: "优甲乐",
            dose: "75µg",
            usage: "早上空腹"
        )
        #expect(value.body == "该吃药了：优甲乐 75µg（早上空腹）")
    }

    @Test("老人版复查通知提醒带旧报告")
    func elderFollowUpNotificationCopy() {
        let value = ElderNotificationCopyBuilder.followUp(
            item: "甲状腺功能"
        )
        #expect(
            value.body
                == "明天要复查了：甲状腺功能，记得带上旧报告"
        )
    }

    @Test("老人通知点击一律落今天页")
    func elderNotificationDestination() {
        #expect(
            ElderNotificationDestinationPolicy.destination(for: .elder)
                == .elderToday
        )
        #expect(
            ElderNotificationDestinationPolicy.destination(for: .standard)
                == .standardRoute
        )
    }

    @Test("引导状态机首屏且默认标准版")
    func onboardingStartsLocalAndStandard() {
        let state = CareThreadOnboardingStateMachine()
        #expect(state.page == .localPrivacy)
        #expect(state.selectedMode == .standard)
        #expect(state.canSkip)
    }

    @Test("引导正常顺序到模式选择")
    func onboardingAdvancesInOrder() {
        var state = CareThreadOnboardingStateMachine()
        state.advance()
        #expect(state.page == .organize)
        state.advance()
        #expect(state.page == .modeChoice)
        #expect(!state.isComplete)
    }

    @Test("跳过只跳到不可跳的模式选择")
    func onboardingSkipStopsAtModeChoice() {
        var state = CareThreadOnboardingStateMachine()
        state.skip()
        #expect(state.page == .modeChoice)
        #expect(!state.canSkip)
        state.skip()
        #expect(state.page == .modeChoice)
        #expect(!state.isComplete)
    }

    @Test("模式选择后才可完成引导")
    func onboardingRequiresModeChoice() {
        var state = CareThreadOnboardingStateMachine()
        state.complete()
        #expect(!state.isComplete)
        state.skip()
        state.selectMode(.elder)
        state.complete()
        #expect(state.isComplete)
        #expect(state.selectedMode == .elder)
    }

    @Test("DEBUG 首启参数可重置引导和空库")
    func onboardingLaunchArguments() {
        let policy = CareThreadOnboardingLaunchPolicy(
            arguments: ["app", "-resetOnboarding", "-uiTestEmpty"]
        )
        #expect(policy.resetOnboarding)
        #expect(policy.useEmptyLibrary)
    }

    @Test("今天页严格隔离当前成员")
    func todaySnapshotIsolatesMember() {
        let first = UUID()
        let second = UUID()
        let now = CTDate.make(2026, 7, 31, hour: 7)
        let snapshot = ElderTodaySnapshotBuilder.build(
            patientID: first,
            medications: [
                medication(patientID: first, name: "成员一药"),
                medication(patientID: second, name: "成员二药")
            ],
            followUps: [],
            records: [
                MedicalRecord(
                    patientId: second,
                    title: "不应计数",
                    eventDate: now,
                    reviewStatus: .pending
                )
            ],
            now: now
        )
        #expect(snapshot.medications.map(\.name) == ["成员一药"])
        #expect(snapshot.pendingReviewCount == 0)
    }

    @Test("今天页只展示有效在用药与准确时刻")
    func todaySnapshotActiveMedication() {
        let patientID = UUID()
        let now = CTDate.make(2026, 7, 31, hour: 9)
        let active = medication(patientID: patientID, name: "优甲乐")
        let ended = Medication(
            patientId: patientID,
            name: "旧药",
            startDate: CTDate.make(2025, 1, 1),
            endDate: CTDate.make(2026, 1, 1),
            lifecycleStatus: .completed
        )
        let snapshot = ElderTodaySnapshotBuilder.build(
            patientID: patientID,
            medications: [ended, active],
            followUps: [],
            records: [],
            now: now
        )
        #expect(snapshot.medications.count == 1)
        #expect(snapshot.medications[0].time == "08:00")
        #expect(snapshot.medications[0].isPast)
    }

    @Test("今天页给出最近待复查倒计时")
    func todaySnapshotFollowUpCountdown() {
        let patientID = UUID()
        let now = CTDate.make(2026, 7, 31)
        let followUp = FollowUp(
            patientId: patientID,
            plannedDate: CTDate.make(2026, 8, 15),
            items: ["甲状腺功能"]
        )
        let snapshot = ElderTodaySnapshotBuilder.build(
            patientID: patientID,
            medications: [],
            followUps: [followUp],
            records: [],
            now: now
        )
        #expect(snapshot.nextFollowUp?.countdownText == "还有 15 天")
        #expect(snapshot.nextFollowUp?.itemText == "甲状腺功能")
    }

    @Test("今天页统计同一成员待核对记录")
    func todaySnapshotPendingCount() {
        let patientID = UUID()
        let now = CTDate.make(2026, 7, 31)
        let records = [
            MedicalRecord(
                patientId: patientID,
                title: "",
                eventDate: now,
                reviewStatus: .pending
            ),
            MedicalRecord(
                patientId: patientID,
                title: "已核",
                eventDate: now,
                reviewStatus: .confirmed
            )
        ]
        let snapshot = ElderTodaySnapshotBuilder.build(
            patientID: patientID,
            medications: [],
            followUps: [],
            records: records,
            now: now
        )
        #expect(snapshot.pendingReviewCount == 1)
    }

    @Test("空 OCR 仍保存待核对记录和不可变原件")
    func emptyOCRStillSavesPendingImmutableOriginal() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构老人")
        context.insert(patient)
        try context.save()
        let temporary = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let vault = try CaptureVaultService(
            rootURL: temporary.appendingPathComponent("Vault")
        )
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 320, height: 240)
        )
        let blank = renderer.image { graphics in
            UIColor.white.setFill()
            graphics.fill(
                CGRect(x: 0, y: 0, width: 320, height: 240)
            )
        }
        let batchID = UUID()
        let staged = try vault.stagePhotoData(
            try #require(blank.pngData()),
            batchID: batchID,
            displayName: "虚构老人版空白报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )

        let result = try await ElderCaptureService(
            context: context,
            vault: vault
        ).save(
            ElderCaptureRequest(
                patientID: patient.id,
                batchID: batchID,
                stagedAssets: [staged],
                source: .fixture,
                typeChoice: .other,
                eventDate: CTDate.make(2026, 7, 31)
            )
        )

        #expect(result.record.reviewStatus == .pending)
        #expect(result.record.patientId == patient.id)
        #expect(result.record.attachments.count == 1)
        #expect(result.record.attachments[0].integrityState == .verified)
        let original = try vault.url(
            for: result.record.attachments[0].originalRelativePath
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: original.path
        )
        #expect(attributes[.immutable] as? Bool == true)
    }

    private func medication(
        patientID: UUID,
        name: String
    ) -> Medication {
        Medication(
            patientId: patientID,
            name: name,
            doseValue: 75,
            doseUnit: "µg",
            usageNotes: ["早上空腹"],
            startDate: CTDate.make(2026, 1, 1),
            reminderEnabled: true,
            reminderTimes: [ReminderTime(hour: 8, minute: 0)]
        )
    }

    private func entityCounts(
        _ context: ModelContext
    ) throws -> [Int] {
        [
            try context.fetchCount(FetchDescriptor<Patient>()),
            try context.fetchCount(FetchDescriptor<MedicalRecord>()),
            try context.fetchCount(FetchDescriptor<Medication>()),
            try context.fetchCount(FetchDescriptor<MedicalOrder>()),
            try context.fetchCount(FetchDescriptor<FollowUp>()),
            try context.fetchCount(FetchDescriptor<Attachment>())
        ]
    }
}
