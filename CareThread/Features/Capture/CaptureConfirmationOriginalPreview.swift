import SwiftUI
import UIKit

/// Reads a staging asset only for rendering. It deliberately has no share
/// action: staging paths are private implementation details, not export URLs.
struct CaptureConfirmationOriginalPreview: View {
    @Environment(\.dismiss) private var dismiss
    let page: M3CapturePageAsset
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableUIImageView(image: image)
                        .background(CT.Color.bgBase)
                } else if !didFail, page.relativePath != nil {
                    ProgressView(Copy.Capture.processing)
                } else if let text = page.ocrText,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(text)
                            .font(CT.Font.bodyReading)
                            .foregroundStyle(CT.Color.inkPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(CT.Space.s5)
                    }
                    .background(CT.Color.bgBase)
                } else {
                    ContentUnavailableView(
                        Copy.Records.missingOriginal,
                        systemImage: "doc.questionmark"
                    )
                }
            }
            .navigationTitle(page.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.done) { dismiss() }
                }
            }
        }
        .task(id: page.rotationQuarterTurns) {
            guard page.relativePath != nil else {
                didFail = true
                return
            }
            do {
                image = try await M3CaptureRecognitionPipeline.renderPreview(
                    page: page,
                    vault: CaptureVaultService()
                )
                didFail = false
            } catch {
                AppLog.vault.error(
                    "Unable to render confirmation staging preview: \(String(describing: error), privacy: .private(mask: .hash))"
                )
                didFail = true
            }
        }
        .accessibilityIdentifier("m3.confirm.originalPreview")
    }
}

struct CaptureConfirmationThumbnail: View {
    let page: M3CapturePageAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: page.kind == .pdf ? "doc.richtext" : "photo")
                    .font(CT.Font.title2)
                    .foregroundStyle(CT.Color.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CT.Color.bgInset)
            }
        }
        .frame(width: CT.Size.detailThumbnail, height: CT.Size.detailThumbnail)
        .clipShape(RoundedRectangle(cornerRadius: CT.Radius.thumbnail))
        .overlay {
            RoundedRectangle(cornerRadius: CT.Radius.thumbnail)
                .stroke(CT.Color.outline, lineWidth: M3Layout.hairline)
        }
        .task(id: page.rotationQuarterTurns) {
            guard page.relativePath != nil else { return }
            image = try? await M3CaptureRecognitionPipeline.renderPreview(
                page: page,
                vault: CaptureVaultService()
            )
        }
    }
}
