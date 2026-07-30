import SwiftData
import SwiftUI
import UIKit

struct BriefWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    let patientID: UUID
    var now: () -> Date = Date.init
    var onPDFExported: (URL) -> Void = { _ in }

    @State private var input: BriefInput?
    @State private var selection = BriefSelection()
    @State private var rangePreset: DateRangePreset = .sixMonths
    @State private var isEditingSelection = false
    @State private var exportItem: M7ShareItem?
    @State private var exportMessage: String?
    @State private var isExporting = false
    @State private var loadFailed = false
    @State private var exportTask: Task<Void, Never>?

    private var document: BriefDocument? {
        input.map {
            BriefBuilder.build(
                input: $0,
                selection: selection,
                generatedAt: now()
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: CT.Space.s4) {
                controls
                if let input {
                    NavigationLink {
                        VisitPreparationCardView(
                            input: input,
                            now: now
                        )
                    } label: {
                        HStack(spacing: CT.Space.s3) {
                            Image(systemName: "doc.text")
                                .font(CT.Font.title3)
                                .foregroundStyle(CT.Color.primary)
                            VStack(
                                alignment: .leading,
                                spacing: CT.Space.s1
                            ) {
                                Text(Copy.VisitPreparation.entryTitle)
                                    .font(CT.Font.headline)
                                    .foregroundStyle(CT.Color.inkPrimary)
                                Text(Copy.VisitPreparation.entrySubtitle)
                                    .font(CT.Font.footnote)
                                    .foregroundStyle(
                                        CT.Color.inkSecondary
                                    )
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.inkTertiary)
                        }
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
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("m7.preparation.entry")
                }
                if loadFailed {
                    M4M5StatusBanner(
                        message: Copy.Brief.loadingFailed,
                        isDanger: true
                    )
                } else if let document, document.hasExportableContent {
                    paper(document)
                } else if input != nil {
                    emptyState
                } else {
                    ProgressView()
                        .frame(minHeight: 220)
                }
                if let exportMessage {
                    Text(exportMessage)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("m7.brief.export.result")
                }
                if isExporting {
                    HStack(spacing: CT.Space.s2) {
                        ProgressView()
                        Text(Copy.Brief.exporting)
                            .font(CT.Font.footnote)
                            .foregroundStyle(CT.Color.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("m7.brief.export.progress")
                }
                M4M5PrimaryButton(
                    title: Copy.Brief.exportAndShare,
                    systemImage: "square.and.arrow.up",
                    isEnabled: document?.hasExportableContent == true
                        && !isExporting,
                    action: export
                )
                .accessibilityIdentifier("m7.brief.export")
            }
            .padding(CT.Space.s5)
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Brief.navigationTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(Copy.Brief.editSelection) {
                    isEditingSelection = true
                }
                .disabled(input == nil)
                .accessibilityIdentifier("m7.brief.edit")
            }
        }
        .sheet(isPresented: $isEditingSelection) {
            if let input {
                BriefSelectionView(
                    input: input,
                    selection: $selection,
                    questions: Binding(
                        get: { self.input?.questions ?? [] },
                        set: { self.input?.questions = $0 }
                    ),
                    onSaveQuestions: persistQuestions
                )
            }
        }
        .sheet(item: $exportItem) { item in
            M7ShareSheet(items: [item.fileURL]) {
                M7TemporaryExportStore().remove(item.fileURL)
                exportItem = nil
            }
        }
        .task(id: patientID) {
            load()
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            discardPendingExport()
        }
        .accessibilityIdentifier("m7.brief")
    }

    private var controls: some View {
        HStack(spacing: CT.Space.s3) {
            Text(Copy.Brief.localOnly)
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
            Spacer()
            Picker("导出范围", selection: $rangePreset) {
                ForEach(DateRangePreset.allCases) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("m7.brief.range")
        }
    }

    private func paper(_ document: BriefDocument) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s5) {
            VStack(alignment: .leading, spacing: CT.Space.s1) {
                Text("CareThread 就诊摘要")
                    .font(CT.Font.title2)
                    .foregroundStyle(CT.Color.inkPrimary)
                Text("\(document.memberName) · \(BriefFormatting.day.string(from: document.generatedAt))")
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
            ForEach(document.sections) { section in
                VStack(alignment: .leading, spacing: CT.Space.s2) {
                    Text(section.title)
                        .font(CT.Font.headline)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: CT.Space.s2) {
                            Text("•")
                            Text(item.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let marker = item.sourceMarker {
                                Text(marker)
                                    .foregroundStyle(CT.Color.primary)
                            }
                        }
                        .font(CT.Font.bodyReading)
                        .foregroundStyle(CT.Color.inkPrimary)
                    }
                }
            }
            if !document.sources.isEmpty {
                VStack(alignment: .leading, spacing: CT.Space.s2) {
                    Text("来源")
                        .font(CT.Font.headline)
                        .foregroundStyle(CT.Color.inkPrimary)
                    ForEach(document.sources) { source in
                        Text(
                            "\(BriefSource.marker(source.number)) \(BriefFormatting.day.string(from: source.eventDate)) \(source.title)"
                        )
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                    }
                }
            }
            Text(document.disclaimer)
                .font(CT.Font.label)
                .foregroundStyle(CT.Color.inkTertiary)
        }
        .padding(CT.Space.s5)
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
            .stroke(CT.Color.outline, lineWidth: CT.Stroke.hairline)
        }
        .accessibilityIdentifier("m7.brief.paper")
    }

    private var emptyState: some View {
        VStack(spacing: CT.Space.s3) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: CT.Size.emptySymbol))
                .foregroundStyle(CT.Color.inkTertiary)
            Text(Copy.Brief.emptyTitle)
                .font(CT.Font.title3)
                .foregroundStyle(CT.Color.inkPrimary)
            Text(Copy.Brief.emptyMessage)
                .font(CT.Font.body)
                .foregroundStyle(CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityIdentifier("m7.brief.empty")
    }

    @MainActor
    private func load() {
        do {
            let value = try M7BriefDataLoader(context: modelContext)
                .load(patientID: patientID)
            input = value
            selection.selectedRecordIDs = Set(
                value.records
                    .filter {
                        $0.patientID == patientID
                            && $0.reviewStatus == .confirmed
                            && $0.isInBrief
                    }
                    .map(\.id)
            )
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.data.error(
                "Brief workspace load failed: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func persistQuestions(_ questions: [String]) {
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == patientID }
        )
        descriptor.fetchLimit = 1
        do {
            guard let patient = try modelContext.fetch(descriptor).first else {
                throw M7BriefDataLoaderError.memberNotFound
            }
            do {
                _ = try PatientProfileService(
                    context: modelContext
                ).replacePendingQuestions(
                    on: patient,
                    texts: questions,
                    expectedRevision: patient.contentRevision
                )
            } catch PatientProfileServiceError.noChanges {
                return
            }
            exportMessage = "问医生的问题已保存到成员资料。"
        } catch {
            exportMessage = "问题保存失败，请刷新后重试。"
            AppLog.data.error("Brief question persistence failed")
        }
    }

    @MainActor
    private func export() {
        guard let input, document?.hasExportableContent == true else {
            AppLog.userAction.warning(
                "Brief export action ignored in empty state"
            )
            return
        }
        exportTask?.cancel()
        discardPendingExport()
        isExporting = true
        exportMessage = nil
        let payload = BriefBuilder.exportPayload(
            input: input,
            preset: rangePreset,
            selection: selection,
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
                exportMessage = "已生成 PDF · \(max(1, result.byteCount / 1_024)) KB · \(result.pageCount) 页"
                exportItem = M7ShareItem(fileURL: result.fileURL)
                onPDFExported(result.fileURL)
            } catch is CancellationError {
                AppLog.userAction.info("Brief PDF export cancelled")
            } catch {
                exportMessage = Copy.Brief.exportFailed
                AppLog.userAction.error(
                    "Brief export user action failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func discardPendingExport() {
        guard let exportItem else { return }
        M7TemporaryExportStore().remove(exportItem.fileURL)
        self.exportItem = nil
    }
}

private struct BriefSelectionView: View {
    let input: BriefInput
    @Binding var selection: BriefSelection
    @Binding var questions: [String]
    let onSaveQuestions: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newQuestion = ""

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
        NavigationStack {
            List {
                Section(Copy.Brief.sections) {
                    ForEach(BriefSectionID.allCases) { section in
                        Toggle(
                            section.title,
                            isOn: Binding(
                                get: {
                                    selection.enabledSections.contains(section)
                                },
                                set: { enabled in
                                    if enabled {
                                        selection.enabledSections.insert(section)
                                    } else {
                                        selection.enabledSections.remove(section)
                                    }
                                }
                            )
                        )
                    }
                }
                Section(Copy.Brief.selectedRecords) {
                    if confirmedRecords.isEmpty {
                        Text("没有已确认记录")
                            .foregroundStyle(CT.Color.inkSecondary)
                    }
                    ForEach(confirmedRecords) { record in
                        Toggle(
                            "\(BriefFormatting.day.string(from: record.eventDate)) \(record.title.isEmpty ? record.type.displayName : record.title)",
                            isOn: recordBinding(record.id)
                        )
                    }
                }
                Section(Copy.Brief.questions) {
                    ForEach(Array(questions.enumerated()), id: \.offset) {
                        index, value in
                        HStack {
                            TextField(
                                "问题",
                                text: Binding(
                                    get: { questions[index] },
                                    set: { questions[index] = $0 }
                                )
                            )
                            Button(role: .destructive) {
                                questions.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    HStack {
                        TextField("想问医生什么？", text: $newQuestion)
                        Button(Copy.Brief.addQuestion) {
                            let value = newQuestion.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            guard !value.isEmpty else { return }
                            questions.append(value)
                            newQuestion = ""
                        }
                        .disabled(
                            newQuestion.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                    }
                }
            }
            .navigationTitle(Copy.Brief.editSelection)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSaveQuestions(questions)
                        AppLog.userAction.info(
                            "Brief section and record selection edited"
                        )
                        dismiss()
                    }
                }
            }
        }
    }

    private func recordBinding(_ recordID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                selection.selectedRecordIDs?.contains(recordID) == true
            },
            set: { selected in
                var ids = selection.selectedRecordIDs ?? []
                if selected {
                    ids.insert(recordID)
                } else {
                    ids.remove(recordID)
                }
                selection.selectedRecordIDs = ids
            }
        )
    }
}

private struct M7ShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct M7ShareSheet: UIViewControllerRepresentable {
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
