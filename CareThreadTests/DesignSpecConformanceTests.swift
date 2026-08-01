import Foundation
import Testing
@testable import CareThread

@MainActor
struct DesignSpecConformanceTests {
    @Test("§12 关键微文案逐字一致")
    func keyCopyMatchesDesignSpecification() {
        #expect(Copy.Home.emptyTitle == "先放进来一份报告")
        #expect(
            Copy.Home.emptyDescription
                == "拍张照片就行，CareThread 会帮你把它串到病程线上。"
        )
        #expect(Copy.Home.emptyCapture == "录入第一份资料")
        #expect(Copy.Home.viewExample == "先看看示例")
        #expect(
            Copy.Records.empty
                == "这里会存放你的所有报告和病历，按时间排好。"
        )
        #expect(
            Copy.Timeline.empty
                == "录入第一份资料后，你的病程线会从这里开始。"
        )
        #expect(
            Copy.Medication.noActive
                == "记下正在吃的药，复诊时不用再翻药盒。"
        )
        #expect(
            Copy.FollowUp.noPlans
                == "把医生说的“过三个月复查”记在这里，到时候会提醒你。"
        )
        #expect(
            Copy.ocrEmpty
                == "没认出文字。可以换张更清晰的照片，或直接手动填写。"
        )
        #expect(Copy.futureDate == "这个日期晚于今天，请核对一下。")
        #expect(Copy.Records.deleteTitle == "要删除这条记录吗？")
        #expect(
            Copy.Records.deleteConfirm
                == "它的原件也会一起从手机里移除，无法恢复。"
        )
        #expect(
            String(format: Copy.Home.pendingFormat, 3)
                == "3 份资料等着你确认"
        )
    }

    @Test("§15.8 长辈版关键微文案逐字一致")
    func elderCopyMatchesDesignSpecification() {
        #expect(Copy.Elder.noMedication == "还没有记录用药，请家人帮忙添加。")
        #expect(Copy.Elder.captureDescription == "拍下报告单，存进手机里")
        #expect(Copy.Elder.typeQuestion == "这是什么？")
        #expect(Copy.Elder.dateQuestion == "哪天的？")
        #expect(Copy.Elder.saved == "存好了 ✓")
        #expect(Copy.Elder.doctorHeader == "把这一页拿给医生看")
        #expect(Copy.Elder.switchToElderTitle == "切换到长辈版？")
        #expect(
            Copy.Elder.switchToElderBody
                == "字更大、操作更简单，资料完全一样，随时可以换回来。"
        )
        #expect(Copy.Elder.switchToStandardTitle == "换回标准版？")
        #expect(
            Copy.Elder.switchToStandardBody
                == "功能更全，适合帮忙整理资料的家人。"
        )
    }

    @Test("§15 长辈版最小触达尺寸满足规范")
    func elderTouchTargetsMeetMinimums() {
        #expect(CT.Size.elderPrimaryButtonHeight >= 60)
        #expect(CT.Size.elderTouchTarget >= 56)
        #expect(CT.Size.elderListRowHeight >= 64)
    }

    @Test("字体 token 使用 Dynamic Type 相对曲线")
    func fontTokensUseDynamicTypeCurves() throws {
        let source = try sourceText("CareThread/DesignSystem/CTFont.swift")
        #expect(source.contains("UIFontMetrics("))
        #expect(source.contains("scaledFont(for: baseFont)"))
        #expect(source.contains("UIFont.systemFont("))
        #expect(source.contains("return SwiftUI.Font(scaledFont)"))
        #expect(!source.contains("baseFont.fontName"))
        #expect(!source.contains("SwiftUI.Font.custom("))
        #expect(!source.contains("SwiftUI.Font.system(size:"))
    }

    @Test("长辈版无隐藏手势且无缩放或循环动画")
    func elderSourcesAvoidHiddenGesturesAndMotionResidue() throws {
        let root = repositoryRoot()
            .appendingPathComponent("CareThread/Features/Elder")
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let combined = try sourceFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        #expect(!combined.contains(".swipeActions"))
        #expect(!combined.contains(".contextMenu"))
        #expect(!combined.contains(".onLongPressGesture"))
        #expect(!combined.contains(".scaleEffect"))
        #expect(!combined.contains(".repeatForever"))
        #expect(!combined.contains(".symbolEffect"))
    }

    @Test("原文从卡片、详情、确认页均一步可达")
    func originalIsOneStepReachable() throws {
        let library = try sourceText(
            "CareThread/Features/Records/RecordLibraryView.swift"
        )
        let detail = try sourceText(
            "CareThread/Features/Records/RecordDetailView.swift"
        )
        let confirmation = try sourceText(
            "CareThread/Features/Capture/CaptureConfirmationView.swift"
        )

        #expect(Copy.viewOriginal == "查看原文")
        #expect(library.contains("selectedOriginalRecord = record"))
        #expect(library.contains("Copy.viewOriginal"))
        #expect(detail.contains("selectedAttachment = record.attachments"))
        #expect(detail.contains("Copy.viewOriginal"))
        #expect(confirmation.contains("selectedOriginalPage = page"))
    }

    @Test("原件缺失时标准版与长辈版均提供备份恢复入口")
    func missingOriginalProvidesBackupRecoveryEntry() throws {
        let standard = try sourceText(
            "CareThread/Features/Records/OriginalViewer.swift"
        )
        let elder = try sourceText(
            "CareThread/Features/Elder/ElderRecordsView.swift"
        )

        #expect(!Copy.Records.missingOriginalGuidance.isEmpty)
        #expect(Copy.Records.recoverOriginal == "从备份恢复原件")
        #expect(standard.contains("m3.viewer.recoverOriginal"))
        #expect(standard.contains("BackupRestoreView(patientID:"))
        #expect(elder.contains("elder.original.recoverOriginal"))
        #expect(elder.contains("BackupRestoreView(patientID:"))
    }

    private func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
