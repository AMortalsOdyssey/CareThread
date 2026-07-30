import SwiftUI
import UIKit

struct VisitPreparationCardView: View {
    let input: BriefInput
    var now: () -> Date = Date.init

    @State private var selection: VisitPreparationSelection
    @State private var contact = ""
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var shareItem: VisitPreparationShareItem?
    @State private var exportTask: Task<Void, Never>?

    init(
        input: BriefInput,
        now: @escaping () -> Date = Date.init
    ) {
        self.input = input
        self.now = now
        _selection = State(
            initialValue: VisitPreparationSelection(
                selectedRecordIDs: Set(
                    input.records
                        .filter {
                            $0.patientID == input.member.id
                                && $0.reviewStatus == .confirmed
                                && ($0.isKeyRecord || $0.isInBrief)
                        }
                        .map(\.id)
                )
            )
        )
    }

    private var document: VisitPreparationCardDocument {
        VisitPreparationCardBuilder.build(
            input: input,
            contact: contact,
            selection: selection,
            generatedAt: now()
        )
    }

    private var confirmedRecords: [BriefRecordSnapshot] {
        input.records
            .filter {
                $0.patientID == input.member.id
                    && $0.reviewStatus == .confirmed
            }
            .sorted {
                if $0.eventDate != $1.eventDate {
                    return $0.eventDate > $1.eventDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s5) {
                noticeCard
                sectionSelectionCard
                recordSelectionCard
                contactCard
                previewCard
                if let exportMessage {
                    Text(exportMessage)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .accessibilityIdentifier(
                            "m7.preparation.export.result"
                        )
                }
                M4M5PrimaryButton(
                    title: Copy.VisitPreparation.exportAndShare,
                    systemImage: "square.and.arrow.up",
                    isEnabled: document.hasExportableContent && !isExporting,
                    action: export
                )
                .accessibilityIdentifier("m7.preparation.export")
            }
            .padding(CT.Space.s5)
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.VisitPreparation.navigationTitle)
        .sheet(item: $shareItem) { item in
            VisitPreparationShareSheet(items: [item.fileURL]) {
                M7TemporaryExportStore().remove(item.fileURL)
                shareItem = nil
            }
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            discardPendingExport()
        }
        .accessibilityIdentifier("m7.preparation")
    }

    private var noticeCard: some View {
        VStack(alignment: .leading, spacing: CT.Space.s2) {
            Label(
                Copy.VisitPreparation.onePagePromise,
                systemImage: "doc.text"
            )
            .font(CT.Font.headline)
            .foregroundStyle(CT.Color.inkPrimary)
            Text(Copy.VisitPreparation.localOnly)
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
        }
        .preparationCardStyle()
        .accessibilityIdentifier("m7.preparation.onePage")
    }

    private var sectionSelectionCard: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            Text(Copy.VisitPreparation.includeSections)
                .font(CT.Font.headline)
                .foregroundStyle(CT.Color.inkPrimary)
            ForEach(VisitPreparationSectionID.allCases) { section in
                Toggle(
                    section.title,
                    isOn: sectionBinding(section)
                )
                .font(CT.Font.body)
                .tint(CT.Color.primary)
                .accessibilityIdentifier(
                    "m7.preparation.section.\(section.rawValue)"
                )
            }
        }
        .preparationCardStyle()
    }

    private var recordSelectionCard: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            Text(Copy.VisitPreparation.selectKeyRecords)
                .font(CT.Font.headline)
                .foregroundStyle(CT.Color.inkPrimary)
            if confirmedRecords.isEmpty {
                Text(Copy.VisitPreparation.noConfirmedRecords)
                    .font(CT.Font.body)
                    .foregroundStyle(CT.Color.inkSecondary)
            } else {
                ForEach(confirmedRecords) { record in
                    Toggle(
                        recordLabel(record),
                        isOn: recordBinding(record.id)
                    )
                    .font(CT.Font.body)
                    .tint(CT.Color.primary)
                }
            }
        }
        .preparationCardStyle()
    }

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            Text(Copy.VisitPreparation.contactInput)
                .font(CT.Font.headline)
                .foregroundStyle(CT.Color.inkPrimary)
            TextField(
                Copy.VisitPreparation.contactPlaceholder,
                text: $contact
            )
            .font(CT.Font.body)
            .padding(.horizontal, CT.Space.s3)
            .frame(minHeight: CT.Size.inputHeight)
            .background(CT.Color.bgInset)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.input,
                    style: .continuous
                )
            )
            .accessibilityIdentifier("m7.preparation.contact")
        }
        .preparationCardStyle()
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            HStack {
                Text(Copy.VisitPreparation.preview)
                    .font(CT.Font.headline)
                    .foregroundStyle(CT.Color.inkPrimary)
                Spacer()
                Text(
                    String(
                        format: Copy.VisitPreparation.itemCount,
                        document.itemCount
                    )
                )
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
            }
            if document.hasExportableContent {
                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Text(section.title)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkPrimary)
                        Text(section.items.map(\.text).joined(separator: "；"))
                            .font(CT.Font.footnote)
                            .foregroundStyle(CT.Color.inkSecondary)
                            .lineLimit(3)
                    }
                }
                if document.omittedItemCount > 0 {
                    Text(
                        String(
                            format: Copy.VisitPreparation.omittedCount,
                            document.omittedItemCount
                        )
                    )
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.warning)
                }
                if document.shortenedItemCount > 0 {
                    Text(
                        String(
                            format: Copy.VisitPreparation.shortenedCount,
                            document.shortenedItemCount
                        )
                    )
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.warning)
                }
            } else {
                Text(Copy.VisitPreparation.emptyTitle)
                    .font(CT.Font.body)
                    .foregroundStyle(CT.Color.inkPrimary)
                Text(Copy.VisitPreparation.emptyMessage)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
        }
        .preparationCardStyle()
        .accessibilityIdentifier("m7.preparation.preview")
    }

    private func sectionBinding(
        _ section: VisitPreparationSectionID
    ) -> Binding<Bool> {
        Binding(
            get: { selection.enabledSections.contains(section) },
            set: { isEnabled in
                if isEnabled {
                    selection.enabledSections.insert(section)
                } else {
                    selection.enabledSections.remove(section)
                }
                AppLog.userAction.info(
                    "Visit preparation section visibility edited"
                )
            }
        )
    }

    private func recordBinding(_ recordID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                selection.selectedRecordIDs?.contains(recordID) == true
            },
            set: { isSelected in
                var ids = selection.selectedRecordIDs ?? []
                if isSelected {
                    ids.insert(recordID)
                } else {
                    ids.remove(recordID)
                }
                selection.selectedRecordIDs = ids
                AppLog.userAction.info(
                    "Visit preparation key-record selection edited"
                )
            }
        )
    }

    private func recordLabel(_ record: BriefRecordSnapshot) -> String {
        let title = record.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return "\(BriefFormatting.day.string(from: record.eventDate)) \(title.isEmpty ? record.type.displayName : title)"
    }

    @MainActor
    private func export() {
        let document = document
        guard document.hasExportableContent else {
            AppLog.userAction.warning(
                "Visit preparation export action ignored in empty state"
            )
            return
        }
        exportTask?.cancel()
        discardPendingExport()
        isExporting = true
        exportMessage = Copy.VisitPreparation.exporting
        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
                let result = try await VisitPreparationPDFService()
                    .exportAsync(document)
                guard !Task.isCancelled else {
                    M7TemporaryExportStore().remove(result.fileURL)
                    throw CancellationError()
                }
                exportMessage = String(
                    format: Copy.VisitPreparation.exportResult,
                    max(1, result.byteCount / 1_024),
                    result.pageCount
                )
                shareItem = VisitPreparationShareItem(
                    fileURL: result.fileURL
                )
            } catch is CancellationError {
                AppLog.userAction.info(
                    "Visit preparation PDF export cancelled"
                )
            } catch {
                exportMessage = Copy.VisitPreparation.exportFailed
                AppLog.userAction.error(
                    "Visit preparation PDF export failed"
                )
            }
        }
    }

    private func discardPendingExport() {
        guard let shareItem else { return }
        M7TemporaryExportStore().remove(shareItem.fileURL)
        self.shareItem = nil
    }
}

private extension View {
    func preparationCardStyle() -> some View {
        self
            .padding(CT.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    CT.Color.outline,
                    lineWidth: CT.Stroke.hairline
                )
            }
    }
}

private struct VisitPreparationShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct VisitPreparationShareSheet: UIViewControllerRepresentable {
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
        private var didComplete = false
        private let onComplete: () -> Void

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func complete() {
            guard !didComplete else { return }
            didComplete = true
            onComplete()
        }
    }
}
