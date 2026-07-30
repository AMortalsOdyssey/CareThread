import SwiftUI

enum CareThreadOnboardingPage: Int, CaseIterable, Codable {
    case localPrivacy
    case organize
    case modeChoice
}

struct CareThreadOnboardingLaunchPolicy: Equatable {
    static let completionKey = "carethread.onboardingCompleted"

    let resetOnboarding: Bool
    let useEmptyLibrary: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        resetOnboarding = arguments.contains("-resetOnboarding")
        useEmptyLibrary = arguments.contains("-uiTestEmpty")
    }

    func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        resetOnboarding
            || !defaults.bool(forKey: Self.completionKey)
    }
}

struct CareThreadOnboardingStateMachine: Equatable {
    private(set) var page: CareThreadOnboardingPage = .localPrivacy
    private(set) var selectedMode: DisplayMode = .standard
    private(set) var isComplete = false

    var canSkip: Bool {
        page != .modeChoice && !isComplete
    }

    mutating func advance() {
        guard !isComplete else { return }
        switch page {
        case .localPrivacy:
            page = .organize
        case .organize:
            page = .modeChoice
        case .modeChoice:
            complete()
        }
    }

    mutating func skip() {
        guard canSkip else { return }
        page = .modeChoice
    }

    mutating func selectMode(_ mode: DisplayMode) {
        guard page == .modeChoice, !isComplete else { return }
        selectedMode = mode
    }

    mutating func complete() {
        guard page == .modeChoice else { return }
        isComplete = true
    }
}

struct CareThreadOnboardingView: View {
    @AppStorage(DisplayMode.storageKey)
    private var storedMode = DisplayMode.standard.rawValue
    @AppStorage(CareThreadOnboardingLaunchPolicy.completionKey)
    private var completed = false
    @State private var state = CareThreadOnboardingStateMachine()

    let onComplete: (DisplayMode) -> Void

    var body: some View {
        VStack(spacing: CT.Space.s5) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("onboarding.root")
            HStack {
                Spacer()
                if state.canSkip {
                    Button("跳过") {
                        state.skip()
                        AppLog.userAction.info(
                            "Onboarding optional pages skipped"
                        )
                    }
                    .font(CT.Font.headline)
                    .frame(minHeight: CT.Size.secondaryButtonHeight)
                    .accessibilityIdentifier("onboarding.skip")
                }
            }
            Group {
                switch state.page {
                case .localPrivacy:
                    localPrivacyPage
                case .organize:
                    organizePage
                case .modeChoice:
                    modeChoicePage
                }
            }
            Spacer()
            HStack(spacing: CT.Space.s2) {
                ForEach(CareThreadOnboardingPage.allCases, id: \.rawValue) {
                    page in
                    Capsule()
                        .fill(
                            page == state.page
                                ? CT.Color.primary
                                : CT.Color.outline
                        )
                        .frame(
                            width: page == state.page
                                ? CT.Space.s6
                                : CT.Space.s2,
                            height: CT.Space.s2
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "第 \(state.page.rawValue + 1) 页，共 3 页"
            )
            if state.page != .modeChoice {
                Button(state.page == .organize ? "我知道了" : "继续") {
                    state.advance()
                }
                .buttonStyle(CTPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.next")
            } else {
                Button("开始使用") {
                    finish()
                }
                .buttonStyle(CTPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.complete")
            }
        }
        .padding(CT.Space.s5)
        .background(CT.Color.bgBase)
        .tint(CT.Color.primary)
    }

    private var localPrivacyPage: some View {
        VStack(spacing: CT.Space.s5) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: CT.Size.elderEmptySymbol))
                .foregroundStyle(CT.Color.primary)
            Text("所有资料只存在这台手机上")
                .font(CT.Font.title1)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                onboardingFact("person.crop.circle.badge.xmark", "不需要账号")
                onboardingFact("square.and.arrow.up", "可以随时导出")
                onboardingFact("faceid", "可以开启应用锁")
            }
        }
        .accessibilityIdentifier("onboarding.localPrivacy")
    }

    private var organizePage: some View {
        VStack(spacing: CT.Space.s5) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: CT.Size.elderEmptySymbol))
                .foregroundStyle(CT.Color.thread)
            Text("把散落的报告，串成一条病程线")
                .font(CT.Font.title1)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
            Text("拍照或导入报告后，CareThread 会在本机整理日期、类型与重要字段。你可以随时核对和修改。")
                .font(CT.Font.bodyReading)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(8)
            Text(Copy.disclaimer)
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("onboarding.organize")
    }

    private var modeChoicePage: some View {
        VStack(spacing: CT.Space.s5) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("onboarding.modeChoice")
            Text("这台手机主要谁在用？")
                .font(CT.Font.title1)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
            modeCard(
                mode: .standard,
                title: "我自己或家人帮忙整理",
                detail: "功能完整，适合核对和管理资料",
                systemImage: "person.2"
            )
            modeCard(
                mode: .elder,
                title: "长辈本人使用（大字简明）",
                detail: "字更大，拍照和查看更简单",
                systemImage: "textformat.size.larger"
            )
            Text("随时可在设置里切换，资料完全一样")
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func onboardingFact(
        _ systemImage: String,
        _ text: String
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(CT.Font.body)
            .foregroundStyle(CT.Color.inkPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeCard(
        mode: DisplayMode,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Button {
            state.selectMode(mode)
        } label: {
            HStack(spacing: CT.Space.s4) {
                Image(systemName: systemImage)
                    .font(CT.Font.title2)
                    .foregroundStyle(CT.Color.primary)
                    .frame(
                        width: CT.Size.leadingIcon,
                        height: CT.Size.leadingIcon
                    )
                VStack(alignment: .leading, spacing: CT.Space.s1) {
                    Text(title)
                        .font(CT.Font.headline)
                        .foregroundStyle(CT.Color.inkPrimary)
                    Text(detail)
                        .font(CT.Font.subhead)
                        .foregroundStyle(CT.Color.inkSecondary)
                }
                Spacer()
                Image(
                    systemName: state.selectedMode == mode
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(CT.Font.title2)
                .foregroundStyle(CT.Color.primary)
            }
            .padding(CT.Space.s4)
            .frame(
                maxWidth: .infinity,
                minHeight: CT.Size.recordCardMinHeight,
                alignment: .leading
            )
            .background(CT.Color.bgElevated)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.card,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: CT.Radius.card,
                    style: .continuous
                )
                .stroke(
                    state.selectedMode == mode
                        ? CT.Color.primary
                        : CT.Color.outline,
                    lineWidth: CT.Stroke.hairline
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.mode.\(mode.rawValue)")
    }

    private func finish() {
        state.complete()
        guard state.isComplete else { return }
        storedMode = state.selectedMode.rawValue
        completed = true
        AppLog.userAction.info(
            "Onboarding completed with selected display mode"
        )
        onComplete(state.selectedMode)
    }
}
