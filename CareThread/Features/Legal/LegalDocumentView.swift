import SwiftUI

struct LegalDocumentView: View {
    let kind: LegalDocumentKind
    var loader = LegalDocumentLoader()
    var usesLargeType = false

    @State private var content = ""
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            Group {
                if let errorMessage {
                    ContentUnavailableView(
                        errorMessage,
                        systemImage: "doc.questionmark"
                    )
                    .accessibilityIdentifier("legal.document.error")
                } else {
                    Text(renderedContent)
                        .font(usesLargeType ? CT.Font.elderBody : CT.Font.bodyReading)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .lineSpacing(usesLargeType ? CT.Space.s3 : CT.Space.s2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("legal.document.content")
                }
            }
            .padding(usesLargeType ? CT.Space.elderScreen : CT.Space.s5)
        }
        .background(CT.Color.bgBase)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: kind.id) {
            loadDocument()
        }
        .accessibilityIdentifier("legal.document.\(kind.rawValue)")
    }

    private var renderedContent: AttributedString {
        guard !content.isEmpty else { return AttributedString("正在读取…") }
        return (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }

    private func loadDocument() {
        do {
            content = try loader.load(kind)
            errorMessage = nil
            AppLog.data.info("Loaded bundled legal document \(kind.rawValue)")
        } catch {
            content = ""
            errorMessage = error.localizedDescription
            AppLog.data.error("Bundled legal document load failed: \(kind.rawValue)")
        }
    }
}
