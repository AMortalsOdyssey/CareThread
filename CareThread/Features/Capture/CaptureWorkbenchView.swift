import QuickLook
import SwiftUI

struct CaptureWorkbenchView: View {
    @ObservedObject var controller: M3CaptureFlowController
    let onAppend: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CT.Space.s5) {
                CTStatusBanner(
                    title: Copy.Capture.userBoundary,
                    message: Copy.Capture.workbenchHelp,
                    tone: .information
                )
                if controller.duplicateSuggestionCount > 0 {
                    CTStatusBanner(
                        title: Copy.Capture.duplicateSuggestionTitle,
                        message: Copy.Capture.duplicateSuggestionMessage(
                            controller.duplicateSuggestionCount
                        ),
                        tone: .warning
                    )
                    .accessibilityIdentifier(
                        "m3.workbench.duplicateSuggestion"
                    )
                }
                if controller.requiresLargeDocumentAcknowledgement {
                    CTStatusBanner(
                        title: Copy.Capture.largeDocumentTitle,
                        message: Copy.Capture.largeDocumentWarning,
                        tone: .warning
                    )
                    Button(Copy.Capture.keepLargeDocumentTogether) {
                        controller.acknowledgeLargeDocument()
                    }
                    .buttonStyle(CTSecondaryButtonStyle())
                    .accessibilityIdentifier("m3.workbench.keepLargeDocument")
                }
                ForEach(Array(controller.documents.enumerated()), id: \.element.id) { documentIndex, document in
                    documentCard(document, index: documentIndex)
                }
                Button(action: onAppend) {
                    Label(Copy.Capture.addPage, systemImage: "plus")
                }
                .buttonStyle(CTSecondaryButtonStyle())
                .accessibilityIdentifier("m3.workbench.addPages")
                HStack(spacing: CT.Space.s3) {
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Text(Copy.Capture.confirmGrouping)
                            .font(CT.Font.headline)
                        Text(
                            Copy.Capture.groupingCount(
                                documents: controller.documents.count,
                                pages: controller.pageCount
                            )
                        )
                            .font(CT.Font.footnote)
                            .foregroundStyle(CT.Color.inkSecondary)
                    }
                    Spacer(minLength: CT.Space.s2)
                    Toggle(
                        Copy.Capture.confirmGrouping,
                        isOn: Binding(
                            get: { controller.groupingConfirmed },
                            set: { newValue in
                                if newValue {
                                    controller.markGroupingConfirmed()
                                } else {
                                    controller.groupingConfirmed = false
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel(Copy.Capture.confirmGrouping)
                    .accessibilityIdentifier("m3.workbench.groupingConfirmed")
                }
                .tint(CT.Color.primary)
                .padding(.vertical, CT.Space.s2)
                Button(action: onContinue) {
                    Text(Copy.Capture.confirmGrouping)
                }
                .buttonStyle(CTPrimaryButtonStyle())
                .disabled(!controller.groupingConfirmed)
                .accessibilityIdentifier("m3.workbench.continue")
            }
            .padding(CT.Space.s4)
        }
        .navigationTitle(Copy.Capture.workbench)
        .fullScreenCover(item: $controller.activePreviewPage) { page in
            CapturePagePreview(page: page)
        }
        .accessibilityIdentifier("m3.workbench")
    }

    @ViewBuilder
    private func documentCard(_ document: M3CaptureDocument, index documentIndex: Int) -> some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                HStack {
                    Label(
                        "\(Copy.Capture.document) \(documentIndex + 1)",
                        systemImage: "doc.on.doc"
                    )
                    .font(CT.Font.headline)
                    .foregroundStyle(CT.Color.inkPrimary)
                    Spacer()
                    Text("\(document.pages.count) \(Copy.Capture.page)")
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                    if documentIndex > 0 {
                        Button {
                            controller.mergeWithPrevious(documentIndex: documentIndex)
                        } label: {
                            Label(Copy.Capture.mergePrevious, systemImage: "arrow.up.to.line.compact")
                                .labelStyle(.iconOnly)
                                .frame(
                                    width: M3Layout.minimumTouchTarget,
                                    height: M3Layout.minimumTouchTarget
                                )
                        }
                        .accessibilityLabel(Copy.Capture.mergePrevious)
                        .accessibilityIdentifier("m3.workbench.merge.\(documentIndex)")
                    }
                }
                ForEach(Array(document.pages.enumerated()), id: \.element.id) { pageIndex, page in
                    if pageIndex > 0 {
                        boundaryControl(
                            page: page,
                            documentIndex: documentIndex,
                            pageIndex: pageIndex
                        )
                    }
                    CapturePageRow(
                        page: page,
                        pageIndex: pageIndex,
                        canMoveUp: pageIndex > 0,
                        canMoveDown: pageIndex < document.pages.count - 1,
                        onPreview: { controller.activePreviewPage = page },
                        onMoveUp: {
                            controller.movePage(
                                documentIndex: documentIndex,
                                pageIndex: pageIndex,
                                offset: -1
                            )
                        },
                        onMoveDown: {
                            controller.movePage(
                                documentIndex: documentIndex,
                                pageIndex: pageIndex,
                                offset: 1
                            )
                        },
                        onRotate: {
                            controller.rotate(documentIndex: documentIndex, pageIndex: pageIndex)
                        },
                        onDelete: {
                            controller.deletePage(documentIndex: documentIndex, pageIndex: pageIndex)
                        }
                    )
                    .accessibilityIdentifier("m3.workbench.page.\(documentIndex).\(pageIndex)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("m3.workbench.document.\(documentIndex)")
    }

    private func boundaryControl(
        page: M3CapturePageAsset,
        documentIndex: Int,
        pageIndex: Int
    ) -> some View {
        HStack(spacing: CT.Space.s2) {
            Rectangle()
                .fill(CT.Color.separator)
                .frame(height: M3Layout.hairline)
            if page.isSuggestedContinuation {
                Label(Copy.Capture.suggestionPrefix, systemImage: "sparkles")
                    .font(CT.Font.caption)
                    .foregroundStyle(CT.Color.warning)
            } else {
                Text(Copy.Capture.reportBoundary)
                    .font(CT.Font.caption)
                    .foregroundStyle(CT.Color.inkTertiary)
            }
            Button(Copy.Capture.split) {
                controller.split(documentIndex: documentIndex, beforePageIndex: pageIndex)
            }
            .font(CT.Font.footnote)
            .accessibilityIdentifier("m3.workbench.split.\(documentIndex).\(pageIndex)")
        }
    }
}

private struct CapturePageRow: View {
    let page: M3CapturePageAsset
    let pageIndex: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onPreview: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRotate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: CT.Space.s3) {
            Button(action: onPreview) {
                ZStack {
                    RoundedRectangle(cornerRadius: CT.Radius.thumbnail)
                        .fill(CT.Color.bgInset)
                    Image(systemName: page.kind == .pdf ? "doc.richtext" : "photo")
                        .font(CT.Font.title2)
                        .foregroundStyle(CT.Color.primary)
                }
                .frame(width: M3Layout.thumbnail, height: M3Layout.thumbnail)
                .rotationEffect(.degrees(Double(page.rotationQuarterTurns * 90)))
            }
            .accessibilityLabel("\(Copy.Capture.original) \(pageIndex + 1)")
            VStack(alignment: .leading, spacing: CT.Space.s1) {
                Text("\(Copy.Capture.page) \(pageIndex + 1)")
                    .font(CT.Font.headline)
                Text(page.displayName)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
                    .lineLimit(2)
                if page.isSuggestedContinuation {
                    Text(Copy.Capture.suggestion)
                        .font(CT.Font.caption)
                        .foregroundStyle(CT.Color.warning)
                }
            }
            Spacer(minLength: CT.Space.s1)
            Menu {
                Button(Copy.Capture.moveUp, systemImage: "arrow.up", action: onMoveUp)
                    .disabled(!canMoveUp)
                Button(Copy.Capture.moveDown, systemImage: "arrow.down", action: onMoveDown)
                    .disabled(!canMoveDown)
                Button(Copy.Capture.rotate, systemImage: "rotate.right", action: onRotate)
                Button(Copy.Capture.delete, systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(
                        width: M3Layout.minimumTouchTarget,
                        height: M3Layout.minimumTouchTarget
                    )
            }
            .accessibilityLabel(Copy.Capture.pageActions)
        }
        .frame(minHeight: M3Layout.thumbnail)
    }
}

private struct CapturePagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let page: M3CapturePageAsset
    @State private var renderedImage: UIImage?
    @State private var didFailRendering = false

    var body: some View {
        NavigationStack {
            Group {
                if let renderedImage {
                    ZoomableUIImageView(image: renderedImage)
                        .background(CT.Color.bgBase)
                } else if page.relativePath != nil, !didFailRendering {
                    ProgressView(Copy.Capture.processing)
                } else if let text = page.ocrText {
                    ScrollView {
                        Text(text)
                            .font(CT.Font.bodyReading)
                            .foregroundStyle(CT.Color.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(CT.Space.s5)
                    }
                    .background(CT.Color.bgBase)
                } else {
                    missing
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
            guard page.relativePath != nil else { return }
            do {
                renderedImage = try await M3CaptureRecognitionPipeline.renderPreview(
                    page: page,
                    vault: CaptureVaultService()
                )
                didFailRendering = false
            } catch {
                didFailRendering = true
            }
        }
    }

    private var missing: some View {
        ContentUnavailableView(
            Copy.Records.missingOriginal,
            systemImage: "doc.questionmark"
        )
    }
}

struct QuickLookURLView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct ZoomableUIImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = M3Layout.viewerMinimumScale
        scroll.maximumZoomScale = M3Layout.viewerMaximumScale
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.accessibilityLabel = Copy.Records.image
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}
