import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import CareThread

// Xcode 26.6 起 Swift Testing 自带 Attachment 类型，与 App 模型撞名；本文件内统一指回 App 模型。
private typealias Attachment = CareThread.Attachment

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

    @Test("大字版 token 覆盖标题正文与元信息")
    func elderTypographyTokens() {
        let value = ElderTypographyValues.resolve(mode: .elder)
        #expect(value.display == 40)
        #expect(value.headline == 22)
        #expect(value.body == 20)
        #expect(value.footnote == 16)
    }

    @Test("大字版按钮行高与触达满足规范")
    func elderComponentSizeTokens() {
        let value = ElderTypographyValues.resolve(mode: .elder)
        #expect(value.primaryButtonHeight == 60)
        #expect(value.listRowHeight == 64)
        #expect(value.touchTarget == 56)
        #expect(CT.Size.elderChoiceButtonHeight == 88)
    }

    @Test("大字版应用内三档字号单调且正文不低于20")
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
        let seedRoot = try TestSupport.temporaryDirectory()
        try SeedService.seedDemo(
            into: context,
            vault: try CaptureVaultService(
                rootURL: seedRoot.appendingPathComponent("Vault")
            )
        )
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

    @Test("长辈选择化验单可明确归为检验")
    func explicitLabChoice() {
        #expect(
            ElderCaptureTypePolicy.resolvedType(
                choice: .lab,
                machineType: .other
            ) == .lab
        )
    }

    @Test("大字版不显示标准版草稿续录入口")
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

    @Test("大字版用药通知使用直白命名空间")
    func elderMedicationNotificationCopy() {
        let value = ElderNotificationCopyBuilder.medication(
            name: "优甲乐",
            dose: "75µg",
            usage: "早上空腹"
        )
        #expect(value.body == "该吃药了：优甲乐 75µg（早上空腹）")
    }

    @Test("大字版复查通知提醒带旧报告")
    func elderFollowUpNotificationCopy() {
        let value = ElderNotificationCopyBuilder.followUp(
            item: "甲状腺功能"
        )
        #expect(
            value.body
                == "明天要复查了：甲状腺功能，记得带上旧报告"
        )
    }

    @Test("长辈通知点击一律落今天页")
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

    @Test("引导第三屏固定为法律同意且不可跳过")
    func onboardingAdvancesInOrder() {
        var state = CareThreadOnboardingStateMachine()
        state.advance()
        #expect(state.page == .modeChoice)
        state.advance()
        #expect(state.page == .legalConsent)
        #expect(!state.canSkip)
        #expect(!state.isComplete)
    }

    @Test("跳过只略过首屏且不能略过法律同意")
    func onboardingSkipStopsAtModeChoice() {
        var state = CareThreadOnboardingStateMachine()
        state.skip()
        #expect(state.page == .modeChoice)
        #expect(!state.canSkip)
        state.skip()
        #expect(state.page == .modeChoice)
        state.advance()
        state.skip()
        #expect(state.page == .legalConsent)
        #expect(!state.isComplete)
    }

    @Test("选择模式并到达法律页后才可完成引导")
    func onboardingRequiresModeChoice() {
        var state = CareThreadOnboardingStateMachine()
        state.complete()
        #expect(!state.isComplete)
        state.skip()
        state.selectMode(.elder)
        state.complete()
        #expect(!state.isComplete)
        state.advance()
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
        let patient = Patient(displayName: "虚构长辈")
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
            displayName: "虚构大字版空白报告.png",
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

    @Test("大字版命中历史精确重复时保留可恢复草稿与原件")
    func duplicateMatchRetainsRecoverableDraftAndStaging() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构长辈甲")
        context.insert(patient)
        let temporary = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let vault = try CaptureVaultService(
            rootURL: temporary.appendingPathComponent("Vault")
        )
        let reportData = try fictionalBlankReportData()
        let existingBatchID = UUID()
        let existingStaged = try vault.stagePhotoData(
            reportData,
            batchID: existingBatchID,
            displayName: "既有虚构重复报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let existingRecordID = UUID()
        let existingFinal = try vault.finalize(
            asset: existingStaged,
            patientID: patient.id,
            recordID: existingRecordID
        )
        let existingRecord = MedicalRecord(
            id: existingRecordID,
            patientId: patient.id,
            title: "既有虚构报告",
            eventDate: CTDate.make(2026, 7, 1),
            sourceType: .photo,
            attachments: [
                try Attachment.verified(
                    id: existingStaged.id,
                    patientId: patient.id,
                    recordId: existingRecordID,
                    originalRelativePath: existingFinal.finalRelativePath,
                    derivedRelativePath: existingFinal.finalPreviewRelativePath,
                    displayFileName: existingStaged.displayName,
                    kind: existingStaged.kind,
                    pageIndex: 0,
                    uniformTypeIdentifier: existingStaged.uniformTypeIdentifier,
                    byteCount: existingStaged.byteCount,
                    sha256: existingStaged.sha256,
                    importedAt: existingStaged.createdAt,
                    importSource: .fixture,
                    pixelWidth: existingStaged.pixelWidth,
                    pixelHeight: existingStaged.pixelHeight,
                    pageCount: existingStaged.pageCount
                )
            ]
        )
        context.insert(existingRecord)
        try context.save()
        try vault.markDatabaseCommitted([existingFinal])
        try vault.completeBatchIfPossible(existingBatchID)

        let batchID = UUID()
        let staged = try vault.stagePhotoData(
            reportData,
            batchID: batchID,
            displayName: "虚构重复报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let baselineRecordCount = try context.fetchCount(
            FetchDescriptor<MedicalRecord>()
        )

        await #expect(
            throws: ElderCaptureError.duplicateRequiresStandardReview
        ) {
            try await ElderCaptureService(
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
        }

        try expectRecoverableElderCapture(
            context: context,
            vault: vault,
            batchID: batchID,
            stagedAsset: staged,
            expectedPatientID: patient.id,
            expectedMedicalRecordCount: baselineRecordCount
        )
    }

    @Test("大字版重复检测异常时保留可恢复草稿与原件")
    func duplicateDetectionFailureRetainsRecoverableDraftAndStaging()
        async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(displayName: "虚构长辈乙")
        context.insert(patient)
        try context.save()
        let temporary = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let vaultRoot = temporary.appendingPathComponent("Vault")
        let vault = try CaptureVaultService(rootURL: vaultRoot)
        let batchID = UUID()
        let staged = try vault.stagePhotoData(
            try fictionalBlankReportData(),
            batchID: batchID,
            displayName: "虚构待检测报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let poisoned = StagedCaptureAsset(
            id: staged.id,
            batchID: staged.batchID,
            originalRelativePath: staged.originalRelativePath,
            previewRelativePath: "../无效预览路径.jpg",
            displayName: staged.displayName,
            fileExtension: staged.fileExtension,
            uniformTypeIdentifier: staged.uniformTypeIdentifier,
            kind: staged.kind,
            byteCount: staged.byteCount,
            sha256: staged.sha256,
            pixelWidth: staged.pixelWidth,
            pixelHeight: staged.pixelHeight,
            pageCount: staged.pageCount,
            createdAt: staged.createdAt
        )
        try replaceJournalAssets(
            [poisoned],
            batchID: batchID,
            vaultRoot: vaultRoot,
            vault: vault
        )
        let baselineRecordCount = try context.fetchCount(
            FetchDescriptor<MedicalRecord>()
        )

        await #expect(
            throws: ElderCaptureError.safetyReviewRequiresStandard
        ) {
            try await ElderCaptureService(
                context: context,
                vault: vault
            ).save(
                ElderCaptureRequest(
                    patientID: patient.id,
                    batchID: batchID,
                    stagedAssets: [poisoned],
                    source: .fixture,
                    typeChoice: .other,
                    eventDate: CTDate.make(2026, 7, 31)
                )
            )
        }

        try expectRecoverableElderCapture(
            context: context,
            vault: vault,
            batchID: batchID,
            stagedAsset: poisoned,
            expectedPatientID: patient.id,
            expectedMedicalRecordCount: baselineRecordCount
        )
    }

    private func fictionalBlankReportData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 320, height: 240)
        )
        let image = renderer.image { graphics in
            UIColor.white.setFill()
            graphics.fill(
                CGRect(x: 0, y: 0, width: 320, height: 240)
            )
        }
        return try #require(image.pngData())
    }

    private func replaceJournalAssets(
        _ assets: [StagedCaptureAsset],
        batchID: UUID,
        vaultRoot: URL,
        vault: CaptureVaultService
    ) throws {
        var journal = try vault.journal(batchID: batchID)
        journal.assets = assets
        journal.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let journalURL = vaultRoot
            .appendingPathComponent("staging")
            .appendingPathComponent(batchID.uuidString)
            .appendingPathComponent("journal.json")
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    private func expectRecoverableElderCapture(
        context: ModelContext,
        vault: CaptureVaultService,
        batchID: UUID,
        stagedAsset: StagedCaptureAsset,
        expectedPatientID: UUID,
        expectedMedicalRecordCount: Int
    ) throws {
        #expect(
            try context.fetchCount(FetchDescriptor<MedicalRecord>())
                == expectedMedicalRecordCount
        )
        #expect(try context.fetchCount(FetchDescriptor<ImportBatch>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CaptureDraft>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CapturePage>()) == 1)
        let draft = try #require(
            context.fetch(FetchDescriptor<CaptureDraft>()).first
        )
        #expect(draft.batchId == batchID)
        #expect(draft.patientId == expectedPatientID)
        let journal = try vault.journal(batchID: batchID)
        #expect(journal.assets == [stagedAsset])
        let originalURL = try vault.url(
            for: stagedAsset.originalRelativePath
        )
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
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
