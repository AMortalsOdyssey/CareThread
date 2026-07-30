import SwiftUI

extension RecordType: Hashable {}
extension AttachmentKind: Hashable {}

extension Copy {
    enum Common {
        static let cancel = "取消"
        static let close = "关闭"
        static let done = "完成"
        static let acknowledge = "知道了"
        static let notRecognized = "未识别"
        static let operationFailed = "操作未完成"
        static let saveFailed = "保存失败"
        static let pendingReview = "待核对"
        static let field = "字段"
        static let value = "值"
        static let numericValue = "数值"
        static let selected = "已选择"
        static let notSelected = "未选择"
    }

    enum Capture {
        static let sourceTitle = "添加资料"
        static let sourceSubtitle = "本次录入会固定到当前成员，保存前不会随页面切换而改变。"
        static let camera = "拍照扫描"
        static let cameraHint = "适合纸质报告，可连续拍摄多页"
        static let photos = "从照片导入"
        static let photosHint = "可一次选择多张截图"
        static let files = "从文件导入"
        static let filesHint = "支持图片与 PDF，不支持视频"
        static let manual = "手动填写"
        static let manualHint = "没有原件，直接创建一条记录"
        static let fixture = "虚构多页样张"
        static let fixtureHint = "DEBUG 专用，不包含真实个人资料"
        static let continueDraft = "继续上次草稿"
        static let noDraft = "目前没有未完成草稿"
        static let workbench = "整理报告页"
        static let workbenchHelp = "每个卡片代表一份报告。请先确认分组；自动识别只提供建议，不会替你合并。"
        static let document = "报告"
        static let page = "页"
        static let split = "从这里拆分"
        static let mergePrevious = "并入上一份"
        static let moveUp = "上移"
        static let moveDown = "下移"
        static let rotate = "旋转"
        static let delete = "删除"
        static let addPage = "继续添加页面"
        static let confirmGrouping = "分组正确，开始识别"
        static let groupingRequired = "请明确确认报告分组后再继续"
        static let suggestion = "识别建议"
        static let suggestionPrefix = "可能与上一页属于同一份报告"
        static let duplicateSuggestionTitle = "发现可能重复的截图"
        static func duplicateSuggestionMessage(_ count: Int) -> String {
            "有 \(count) 组相邻页面文字高度相似。CareThread 不会自动删除原件，请逐页预览后自行保留或删除。"
        }
        static let userBoundary = "以你的分组为准"
        static let processing = "正在本机整理"
        static let processingDetail = "文字识别和字段提取只在这台 iPhone 上完成。"
        static let cancelProcessing = "取消并保留草稿"
        static let confirmation = "核对资料"
        static let frozenMember = "本次录入对象"
        static let adoptAll = "全部采用识别结果"
        static let saveDraft = "存草稿"
        static let draftSaved = "草稿已保留"
        static let machineValue = "识别值"
        static let yourValue = "确认值"
        static let title = "标题"
        static let summary = "摘要"
        static let type = "资料类型"
        static let date = "发生日期"
        static let hospital = "医院"
        static let department = "科室"
        static let doctor = "医生"
        static let diseases = "病种（多个用顿号分隔）"
        static let metrics = "指标"
        static let ageAtEvent = "当时年龄"
        static let ageAtEventHint = "成员未填写生日，可手动填写 0–130 岁"
        static let ageAtEventInvalid = "请输入 0–130 的整数，或留空"
        static let futureDateTitle = "这个日期晚于今天，请核对一下。"
        static let futureDateBody = "仍可保存；记录会标记为待核对。"
        static let ocrEmptyTitle = "没认出文字"
        static let ocrEmptyBody = "可以换张更清晰的照片，或直接手动填写。"
        static let abnormalItems = "异常项"
        static let abnormalPlaceholder = "例如：TSH 偏高"
        static let addAbnormal = "添加异常项"
        static let removeAbnormal = "删除异常项"
        static let addMetric = "添加检验项"
        static let removeMetric = "删除检验项"
        static let metricName = "项目名称"
        static let metricValue = "数值"
        static let metricUnit = "单位"
        static let metricReferenceLow = "参考下限"
        static let metricReferenceHigh = "参考上限"
        static let metricFlag = "箭头"
        static let metricNone = "无"
        static let metricLow = "↓"
        static let metricHigh = "↑"
        static let metricPositive = "阳性"
        static let metricBlankValue = "数值留空时不会用 0 代替，也不会保存该行。"
        static let metricInvalid = "数值或参考范围格式有误，请核对。"
        static let linkedSuggestions = "联动建议"
        static let medicationSuggestion = "发现用药信息"
        static let followUpSuggestion = "发现复查要求"
        static let createMedication = "创建用药记录"
        static let createFollowUp = "创建复查计划"
        static let attachmentStrip = "原件"
        static let requiredFieldsHint = "必填仅资料类型和发生日期；标题可留空。"
        static let original = "查看原件"
        static let save = "确认并保存"
        static let saved = "已保存到当前成员"
        static let mismatchTitle = "姓名与当前成员不一致"
        static let mismatchBody = "为避免病历串档，当前不能直接保存。你可以切换到识别到的成员，或确认这是姓名识别错误。"
        static let ambiguousTitle = "识别到多个姓名"
        static let ambiguousBody = "请先核对报告分组。若原件确实属于当前成员，可走“姓名识别可能有误”的二次确认。"
        static let returnToGrouping = "返回重新分组"
        static let switchMember = "切换到匹配成员"
        static func switchMemberAction(_ name: String) -> String {
            "\(switchMember)：\(name)"
        }
        static func saveAfterSwitch(_ name: String) -> String {
            "已切换至 \(name)，确认保存"
        }
        static let nameRecognitionWrong = "姓名识别可能有误"
        static let overrideConfirmTitle = "再次确认"
        static let overrideConfirmBody = "确认后，这份资料会添加到本次录入固定的成员，并留存本机审计记录。"
        static let overrideReason = "原件属于当前成员，OCR 姓名识别有误"
        static let confirmOverride = "确认识别有误并保存"
        static let noNameEvidence = "未从原件中识别到姓名，请核对后保存。"
        static let importFailure = "无法导入所选文件"
        static let videoRejected = "暂不支持视频。请选择图片或 PDF。"
        static let saveFailure = "保存失败，请保留草稿后重试。"
        static let pageLimit = "单份报告最多 50 页；一次最多导入 100 页。"
        static let largeDocumentTitle = "这份报告页数较多"
        static let largeDocumentWarning = "当前报告超过 20 页，建议按报告边界拆分，便于核对和检索。若确认属于同一份报告，也可以继续。"
        static let keepLargeDocumentTogether = "确认属于同一份报告，继续"
        static let emptyDocument = "每份报告至少需要一页。"
        static let pdfBoundaryLocked = "同一个 PDF 只保存一份不可变原件，不能在文件内部拆成两条记录。"
        static let keepDraftTitle = "保留为草稿？"
        static let keepDraft = "保留草稿"
        static let continueEditing = "继续整理"
        static let keepDraftBody = "已导入的页面会保留在本机，下次可从“继续上次草稿”进入。"
        static let matchedNameTitle = "姓名已匹配"
        static let matchedNameBody = "原件中的可靠姓名与当前成员一致。"
        static let verifyOwnerTitle = "请核对归属"
        static let reportBoundary = "报告边界"
        static let pageActions = "页面操作"
        static func progress(_ completed: Int, _ total: Int) -> String {
            "\(completed) / \(total) 页"
        }
        static func savedCount(_ count: Int) -> String {
            "共保存 \(count) 份报告"
        }
        static func documentProgress(_ current: Int, _ total: Int) -> String {
            "第 \(current) / \(total) 份"
        }
        static func attachmentPage(_ index: Int) -> String {
            "查看第 \(index) 页原件"
        }
        static func medicationSuggestionText(_ hint: MedicationHint) -> String {
            let dose = hint.doseValue.map {
                $0.formatted(.number.precision(.fractionLength(0...4)))
            }
            let parts = [
                hint.name,
                [dose, hint.doseUnit].compactMap { $0 }.joined(),
                hint.frequencyPerDay.map { "每日 \($0) 次" }
            ].compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            return parts.joined(separator: " · ")
        }
        static func followUpSuggestionText(_ hint: FollowUpHint) -> String {
            let items = hint.items.joined(separator: "、")
            if !items.isEmpty { return items }
            return hint.rawText
        }
        static func groupingCount(documents: Int, pages: Int) -> String {
            "\(documents) 份报告 · \(pages) 页"
        }
        static func draftPage(_ index: Int) -> String {
            "草稿页 \(index)"
        }
        static func scanPage(_ index: Int) -> String {
            "扫描页 \(index)"
        }
        static func photoPage(_ index: Int) -> String {
            "照片 \(index)"
        }
        static func fixtureLabPage(_ index: Int) -> String {
            "虚构检验报告 · 第 \(index) 页"
        }
        static func fixtureImagingPage(_ index: Int) -> String {
            "虚构影像报告 · 第 \(index) 页"
        }
        static func importedFilePage(_ fileName: String, _ index: Int) -> String {
            "\(fileName) · 第 \(index) 页"
        }
    }

    enum Records {
        static let navigationTitle = "记录"
        static let search = "搜索标题、医院、摘要"
        static let filters = "筛选与排序"
        static let clearFilters = "清除筛选"
        static let recordType = "资料类型"
        static let hospital = "医院"
        static let doctor = "医生"
        static let disease = "病种"
        static let age = "发生时年龄"
        static let dateRange = "日期范围"
        static let all = "全部"
        static let sort = "排序"
        static let newestFirst = "日期从新到旧"
        static let oldestFirst = "日期从旧到新"
        static let titleSort = "标题"
        static let apply = "应用"
        static let loadMore = "加载更多"
        static let loading = "正在读取本地记录"
        static let empty = "这里会存放你的所有报告和病历，按时间排好。"
        static let emptyFiltered = "没有符合当前筛选的记录"
        static let detail = "记录详情"
        static let edit = "编辑"
        static let delete = "删除"
        static let deleteTitle = "要删除这条记录吗？"
        static let deleteConfirm = "它的原件也会一起从手机里移除，无法恢复。"
        static let keyRecord = "关键记录"
        static let inBrief = "加入就诊摘要"
        static let summary = "摘要"
        static let metrics = "指标"
        static let fields = "结构化字段"
        static let originals = "原件"
        static let related = "相关信息"
        static let noOriginal = "这条手动记录没有原件"
        static let machineSection = "原始识别结果"
        static let editTitle = "编辑记录"
        static let save = "保存修改"
        static let revisionNotice = "修改会生成本机版本记录，原始识别结果不会被覆盖。"
        static let revisionConflict = "这条记录刚刚在其他页面被修改。为避免覆盖新内容，请关闭编辑页后重新打开。"
        static let viewer = "原件"
        static let image = "图片"
        static let pdf = "PDF"
        static let ocr = "识别文字"
        static let shareCopy = "发送或保存副本"
        static let missingOriginal = "原件暂时无法读取"
        static let currentMember = "当前成员"
        static let readFailureTitle = "无法读取记录"
        static let readFailureBody = "本地资料没有被修改，请稍后重试。"
        static let startDate = "起始日期"
        static let fromDate = "从"
        static let endDate = "结束日期"
        static let toDate = "到"
        static let filterByAge = "按年龄筛选"
        static let localDataSafe = "本地资料没有被部分覆盖，请稍后重试。"
        static let recordSettings = "记录设置"
        static let addMemberFirst = "请先添加成员"
        static let defaultMember = "我的档案"
        static let pendingInbox = "待整理收件箱"
        static let pendingReviewOnly = "只看待核对资料"
        static let reviewStatus = "整理状态"
        static let pendingInboxShowing = "正在只看待核对资料，点这里返回全部"
        static func pendingInboxCount(_ count: Int) -> String {
            "\(count) 份资料还需要核对，点这里集中整理"
        }
    }
}

extension MedicalRecord {
    /// A presentation-only fallback. The persisted title stays empty so
    /// `needsInfo` remains truthful and exports never invent a user title.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? type.displayName : trimmed
    }
}

enum M3Layout {
    static let minimumTouchTarget = CT.Size.secondaryButtonHeight
    static let thumbnail = CT.Size.detailThumbnail
    static let sourceIcon = CT.Size.leadingIcon
    static let emptySymbol = CT.Size.emptySymbol
    static let cardMinHeight = CT.Size.recordCardMinHeight
    static let hairline = CT.Space.s1 / CT.Space.s1
    static let compactControlWidth = CT.Size.primaryButtonHeight * 2
    static let viewerMinimumScale: CGFloat = 1
    static let viewerMaximumScale: CGFloat = 5
}

struct CTCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(CT.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CT.Color.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: CT.Radius.card)
                    .stroke(CT.Color.outline, lineWidth: M3Layout.hairline)
            }
    }
}

struct CTPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CT.Font.headline)
            .foregroundStyle(CT.Color.inkOnPrimary)
            .frame(maxWidth: .infinity, minHeight: CT.Size.primaryButtonHeight)
            .background(configuration.isPressed ? CT.Color.primaryPressed : CT.Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.primaryButton))
    }
}

struct CTSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CT.Font.headline)
            .foregroundStyle(CT.Color.primary)
            .frame(maxWidth: .infinity, minHeight: CT.Size.secondaryButtonHeight)
            .background(configuration.isPressed ? CT.Color.primaryContainer : CT.Color.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.secondaryButton))
            .overlay {
                RoundedRectangle(cornerRadius: CT.Radius.secondaryButton)
                    .stroke(CT.Color.outline, lineWidth: M3Layout.hairline)
            }
    }
}

struct CTStatusBanner: View {
    enum Tone {
        case information
        case warning
        case danger

        var background: Color {
            switch self {
            case .information: CT.Color.primaryContainer
            case .warning: CT.Color.warningContainer
            case .danger: CT.Color.dangerContainer
            }
        }

        var foreground: Color {
            switch self {
            case .information: CT.Color.primaryOnContainer
            case .warning: CT.Color.warningOnContainer
            case .danger: CT.Color.dangerOnContainer
            }
        }
    }

    let title: String
    let message: String
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: CT.Space.s2) {
            Text(title)
                .font(CT.Font.headline)
            Text(message)
                .font(CT.Font.subhead)
        }
        .foregroundStyle(tone.foreground)
        .padding(CT.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background)
        .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card))
    }
}

extension RecordType {
    var symbolName: String {
        switch self {
        case .imaging: "waveform.path.ecg.rectangle"
        case .lab: "testtube.2"
        case .pathology: "microbe"
        case .discharge: "door.left.hand.open"
        case .outpatient: "stethoscope"
        case .prescription: "pills"
        case .other: "doc.text"
        }
    }

    var semanticColor: Color {
        switch self {
        case .imaging: CT.Color.imaging
        case .lab: CT.Color.lab
        case .pathology: CT.Color.pathology
        case .discharge: CT.Color.discharge
        case .outpatient: CT.Color.outpatient
        case .prescription: CT.Color.prescription
        case .other: CT.Color.other
        }
    }
}
