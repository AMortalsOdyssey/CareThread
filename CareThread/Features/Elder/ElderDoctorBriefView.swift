import SwiftData
import SwiftUI
import UIKit

struct ElderDoctorBriefView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let patientID: UUID
    var now: () -> Date = Date.init

    @State private var input: BriefInput?
    @State private var shareItem: ElderShareItem?
    @State private var exportError = false
    @State private var loadFailed = false
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?

    private var document: BriefDocument? {
        input.map {
            BriefBuilder.build(input: $0, generatedAt: now())
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s5) {
                Text(Copy.Elder.doctorHeader)
                    .font(CT.Font.elderTitle2)
                    .foregroundStyle(CT.Color.primary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("elder.brief.header")
                if loadFailed {
                    Text(Copy.Brief.loadingFailed)
                        .font(CT.Font.elderBody)
                        .foregroundStyle(CT.Color.danger)
                } else if let document,
                          document.hasExportableContent {
                    briefContent(document)
                } else if input != nil {
                    Text(Copy.Elder.doctorEmpty)
                        .font(CT.Font.elderBody)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, minHeight: 260)
                        .accessibilityIdentifier("elder.brief.empty")
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
                Button {
                    export()
                } label: {
                    if isExporting {
                        HStack(spacing: CT.Space.s2) {
                            ProgressView()
                            Text(Copy.Brief.exporting)
                        }
                    } else {
                        Label(
                            Copy.Elder.exportPrint,
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
                .buttonStyle(ElderPrimaryButtonStyle())
                .disabled(
                    document?.hasExportableContent != true || isExporting
                )
                .accessibilityIdentifier("elder.brief.export")
            }
            .padding(CT.Space.elderScreen)
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Elder.doctorBrief)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(Copy.Common.close) {
                    dismiss()
                }
                .font(CT.Font.elderSubhead)
                .frame(minHeight: CT.Size.elderTouchTarget)
            }
        }
        .sheet(item: $shareItem) { item in
            ElderSystemShareSheet(items: [item.url]) {
                M7TemporaryExportStore().remove(item.url)
                shareItem = nil
            }
        }
        .alert(
            Copy.Brief.exportFailed,
            isPresented: $exportError
        ) {
            Button(Copy.Common.acknowledge) {}
        }
        .task(id: patientID) {
            load()
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            discardPendingExport()
        }
        .dynamicTypeSize(...ElderDynamicTypePolicy.maximum)
        .accessibilityIdentifier("elder.brief")
    }

    private func briefContent(
        _ document: BriefDocument
    ) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s5) {
            ForEach(document.sections) { section in
                VStack(alignment: .leading, spacing: CT.Space.s3) {
                    Text(section.title)
                        .font(CT.Font.elderHeadline)
                        .foregroundStyle(CT.Color.inkPrimary)
                    ForEach(section.items) { item in
                        HStack(alignment: .top, spacing: CT.Space.s2) {
                            Text("•")
                            Text(item.text)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                            if let marker = item.sourceMarker {
                                Text(marker)
                                    .foregroundStyle(CT.Color.primary)
                            }
                        }
                        .font(CT.Font.elderBody)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .lineSpacing(12)
                    }
                }
            }
            Text(document.disclaimer)
                .font(CT.Font.elderFootnote)
                .foregroundStyle(CT.Color.inkSecondary)
                .lineSpacing(8)
        }
        .padding(CT.Space.elderCard)
        .background(CT.Color.bgElevated)
        .clipShape(
            RoundedRectangle(
                cornerRadius: CT.Radius.elderCard,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: CT.Radius.elderCard,
                style: .continuous
            )
            .stroke(CT.Color.outline, lineWidth: CT.Stroke.hairline)
        }
    }

    @MainActor
    private func load() {
        do {
            input = try M7BriefDataLoader(context: modelContext)
                .load(patientID: patientID)
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.data.error(
                "Elder brief load failed: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func export() {
        guard let input, document?.hasExportableContent == true else {
            return
        }
        exportTask?.cancel()
        discardPendingExport()
        isExporting = true
        let payload = BriefBuilder.exportPayload(
            input: input,
            preset: .sixMonths,
            generatedAt: now()
        )
        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
                let result = try await M7PDFExportService()
                    .exportAsync(payload)
                guard !Task.isCancelled else {
                    M7TemporaryExportStore().remove(result.fileURL)
                    throw CancellationError()
                }
                shareItem = ElderShareItem(url: result.fileURL)
                AppLog.userAction.info(
                    "Elder brief export and print sheet opened"
                )
            } catch is CancellationError {
                AppLog.userAction.info("Elder brief PDF export cancelled")
            } catch {
                exportError = true
                AppLog.userAction.error(
                    "Elder brief export failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func discardPendingExport() {
        guard let shareItem else { return }
        M7TemporaryExportStore().remove(shareItem.url)
        self.shareItem = nil
    }
}

private struct ElderShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ElderSystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = {
            _, _, _, _ in context.coordinator.complete()
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}

    final class Coordinator {
        private var completed = false
        private let onComplete: () -> Void

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func complete() {
            guard !completed else { return }
            completed = true
            onComplete()
        }
    }
}
