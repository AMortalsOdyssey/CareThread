import SwiftUI

struct OriginalViewer: View {
    enum Segment: String, CaseIterable, Identifiable {
        case original
        case ocr

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let record: MedicalRecord
    @State private var selectedAttachmentID: UUID
    @State private var segment: Segment = .original
    @State private var shareURL: URL?

    init(
        record: MedicalRecord,
        initialAttachmentID: UUID,
        initialSegment: Segment = .original
    ) {
        self.record = record
        _selectedAttachmentID = State(initialValue: initialAttachmentID)
        _segment = State(initialValue: initialSegment)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: CT.Space.s3) {
                Picker(Copy.Records.viewer, selection: $segment) {
                    Text(selectedAttachment?.kind == .pdf ? Copy.Records.pdf : Copy.Records.image)
                        .tag(Segment.original)
                    Text(Copy.Records.ocr)
                        .tag(Segment.ocr)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, CT.Space.s4)
                .accessibilityIdentifier("m3.viewer.segment")

                Group {
                    switch segment {
                    case .original:
                        originalContent
                    case .ocr:
                        ocrContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if attachments.count > 1 {
                    attachmentStrip
                }
            }
            .background(CT.Color.viewerChrome)
            .navigationTitle(Copy.Records.viewer)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.done) { dismiss() }
                        .foregroundStyle(CT.Color.inkOnPrimary)
                }
                ToolbarItem(placement: .primaryAction) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label(Copy.Records.shareCopy, systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }
                        .foregroundStyle(CT.Color.inkOnPrimary)
                        .accessibilityLabel(Copy.Records.shareCopy)
                        .accessibilityIdentifier("m3.viewer.share")
                    }
                }
            }
            .toolbarBackground(CT.Color.viewerChrome, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task(id: selectedAttachmentID) {
            shareURL = makeShareURL()
        }
        .accessibilityIdentifier("m3.viewer")
    }

    private var attachments: [Attachment] {
        record.attachments.sorted { $0.pageIndex < $1.pageIndex }
    }

    private var selectedAttachment: Attachment? {
        attachments.first(where: { $0.id == selectedAttachmentID }) ?? attachments.first
    }

    @ViewBuilder
    private var originalContent: some View {
        if let attachment = selectedAttachment,
           let url = try? CaptureVaultService().url(
               for: attachment.originalFileName ?? attachment.fileName
           ) {
            QuickLookURLView(url: url)
                .background(CT.Color.bgBase)
        } else {
            missingOriginal
        }
    }

    private var ocrContent: some View {
        ScrollView {
            Text(record.ocrText ?? Copy.ocrEmpty)
                .font(CT.Font.bodyReading)
                .foregroundStyle(CT.Color.inkPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CT.Space.s5)
        }
        .background(CT.Color.bgBase)
    }

    private var missingOriginal: some View {
        VStack(spacing: CT.Space.s4) {
            ContentUnavailableView(
                Copy.Records.missingOriginal,
                systemImage: "doc.questionmark",
                description: Text(Copy.Records.missingOriginalGuidance)
            )
            NavigationLink {
                BackupRestoreView(patientID: record.patientId)
            } label: {
                Label(
                    Copy.Records.recoverOriginal,
                    systemImage: "externaldrive.badge.timemachine"
                )
                .font(CT.Font.headline)
                .frame(minHeight: CT.Size.primaryButtonHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(CT.Color.primary)
            .accessibilityIdentifier("m3.viewer.recoverOriginal")
        }
        .padding(CT.Space.s5)
        .foregroundStyle(CT.Color.inkOnPrimary)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: CT.Space.s2) {
                ForEach(attachments, id: \.id) { attachment in
                    Button {
                        selectedAttachmentID = attachment.id
                        segment = .original
                    } label: {
                        VStack(spacing: CT.Space.s1) {
                            Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "photo")
                                .frame(
                                    width: CT.Size.secondaryButtonHeight,
                                    height: CT.Size.secondaryButtonHeight
                                )
                                .background(
                                    attachment.id == selectedAttachmentID
                                        ? CT.Color.primary
                                        : CT.Color.bgInset
                                )
                                .foregroundStyle(
                                    attachment.id == selectedAttachmentID
                                        ? CT.Color.inkOnPrimary
                                        : CT.Color.inkPrimary
                                )
                                .clipShape(RoundedRectangle(cornerRadius: CT.Radius.thumbnail))
                            Text("\(attachment.pageIndex + 1)")
                                .font(CT.Font.caption)
                                .foregroundStyle(CT.Color.inkOnPrimary)
                        }
                    }
                    .accessibilityLabel("\(Copy.Capture.page) \(attachment.pageIndex + 1)")
                }
            }
            .padding(.horizontal, CT.Space.s4)
        }
        .scrollIndicators(.hidden)
        .frame(minHeight: CT.Size.detailThumbnail)
    }

    private func makeShareURL() -> URL? {
        guard let attachment = selectedAttachment else { return nil }
        guard let vault = try? CaptureVaultService() else { return nil }
        return try? VaultShareCopyService(vault: vault).makeCopy(
            for: attachment,
            patientID: record.patientId,
            recordID: record.id
        )
    }
}
