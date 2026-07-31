import SwiftUI
import UIKit

struct AboutCareThreadView: View {
    let usesLargeType: Bool
    @State private var didCopyFeedbackAddress = false

    private let feedbackAddress = "jianghaibo@multiego.me"

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: CT.Space.s2) {
                    Text("CareThread")
                        .font(usesLargeType ? CT.Font.elderTitle2 : CT.Font.title2)
                        .foregroundStyle(CT.Color.inkPrimary)
                    Text(usesLargeType
                         ? "帮你把就医资料整理好。资料只放在这台手机上。"
                         : "完全本地的个人就医资料整理工具。无账号，不上传资料。")
                        .font(usesLargeType ? CT.Font.elderBody : CT.Font.body)
                        .foregroundStyle(CT.Color.inkSecondary)
                }
                .padding(.vertical, CT.Space.s2)
            }

            Section("隐私与协议") {
                legalLink(.privacyPolicy)
                legalLink(.termsOfService)
            }

            Section("医疗免责") {
                Text(usesLargeType
                     ? "这里只整理你自己的资料，不判断病情，也不告诉你该怎么治疗或吃药。医疗决定请听医生的。"
                     : Copy.disclaimer)
                    .font(usesLargeType ? CT.Font.elderBody : CT.Font.body)
                    .foregroundStyle(CT.Color.inkPrimary)
                    .accessibilityIdentifier("about.medicalDisclaimer")
            }

            Section("软件信息") {
                LabeledContent("版本", value: AppVersionDisplay.current)
                    .font(usesLargeType ? CT.Font.elderBody : CT.Font.body)
                    .accessibilityIdentifier("about.version")
                NavigationLink {
                    OpenSourceLicensesView(usesLargeType: usesLargeType)
                } label: {
                    Label("开源许可", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(usesLargeType ? CT.Font.elderBody : CT.Font.body)
                        .foregroundStyle(CT.Color.inkPrimary)
                }
                .accessibilityIdentifier("about.openSource")
            }

            Section("反馈") {
                Button {
                    UIPasteboard.general.string = feedbackAddress
                    didCopyFeedbackAddress = true
                    AppLog.userAction.info("Feedback email address copied")
                } label: {
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Label("复制反馈邮箱", systemImage: "doc.on.doc")
                            .font(usesLargeType ? CT.Font.elderBody : CT.Font.body)
                        Text(feedbackAddress)
                            .font(usesLargeType ? CT.Font.elderSubhead : CT.Font.footnote)
                            .foregroundStyle(CT.Color.inkSecondary)
                    }
                    .foregroundStyle(CT.Color.primary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: usesLargeType
                            ? CT.Size.elderTouchTarget
                            : CT.Size.secondaryButtonHeight,
                        alignment: .leading
                    )
                }
                .accessibilityIdentifier("about.feedback")
                if didCopyFeedbackAddress {
                    Text("邮箱已复制。你可以打开自己的邮件 App 发送反馈。")
                        .font(usesLargeType ? CT.Font.elderSubhead : CT.Font.footnote)
                        .foregroundStyle(CT.Color.success)
                        .accessibilityIdentifier("about.feedback.copied")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(usesLargeType ? "关于与免责" : "关于 CareThread")
        .dynamicTypeSize(...maximumDynamicTypeSize)
        .accessibilityIdentifier(usesLargeType ? "elder.about" : "about.standard")
    }

    private func legalLink(_ kind: LegalDocumentKind) -> some View {
        NavigationLink {
            LegalDocumentView(kind: kind, usesLargeType: usesLargeType)
        } label: {
            Label(
                kind.title,
                systemImage: kind == .privacyPolicy ? "hand.raised" : "doc.text"
            )
            .font(usesLargeType ? CT.Font.elderBody : CT.Font.body)
            .foregroundStyle(CT.Color.inkPrimary)
            .frame(
                minHeight: usesLargeType
                    ? CT.Size.elderTouchTarget
                    : CT.Size.secondaryButtonHeight
            )
        }
        .accessibilityIdentifier("about.legal.\(kind.rawValue)")
    }

    private var maximumDynamicTypeSize: DynamicTypeSize {
        usesLargeType ? ElderDynamicTypePolicy.maximum : .accessibility5
    }
}

struct OpenSourceLicensesView: View {
    let usesLargeType: Bool

    var body: some View {
        List {
            Section("CareThread") {
                Text("Copyright © 2026 AMortalsOdyssey\nMIT License")
            }
            Section("ZIPFoundation 0.9.20") {
                Text("Copyright © 2017–2025 Thomas Zoechling\nMIT License")
            }
            Section("MIT License") {
                Text(Self.mitLicense)
                    .textSelection(.enabled)
            }
        }
        .font(usesLargeType ? CT.Font.elderBody : CT.Font.bodyReading)
        .foregroundStyle(CT.Color.inkPrimary)
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("about.licenses")
    }

    private static let mitLicense = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

enum AppVersionDisplay {
    static var current: String {
        current(bundle: .main)
    }

    static func current(bundle: Bundle) -> String {
        let marketing = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(marketing) (\(build))"
    }
}
