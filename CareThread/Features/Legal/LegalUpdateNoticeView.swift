import SwiftUI

struct LegalUpdateNoticeView: View {
    let onAcknowledge: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("本次变更摘要") {
                    Text(LegalAgreement.currentChangeSummary)
                        .font(CT.Font.bodyReading)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .accessibilityIdentifier("legal.update.summary")
                }
                Section("查看全文") {
                    NavigationLink("隐私政策") {
                        LegalDocumentView(kind: .privacyPolicy)
                    }
                    NavigationLink("用户协议") {
                        LegalDocumentView(kind: .termsOfService)
                    }
                }
                Section {
                    Button("我已了解") {
                        AppLog.userAction.info("Legal update summary acknowledged")
                        onAcknowledge()
                    }
                    .buttonStyle(CTPrimaryButtonStyle())
                    .accessibilityIdentifier("legal.update.acknowledge")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CT.Color.bgBase)
            .navigationTitle("隐私与协议有更新")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("legal.update")
    }
}
