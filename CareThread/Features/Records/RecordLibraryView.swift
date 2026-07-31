import ImageIO
import SwiftData
import SwiftUI
import UIKit

struct RecordLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var patientID: UUID?
    let patients: [Patient]
    let refreshToken: Int

    @StateObject private var viewModel = M3RecordLibraryViewModel()
    @State private var showFilters = false
    @State private var selectedOriginalRecord: MedicalRecord?

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView(Copy.Records.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                if viewModel.records.isEmpty {
                    ProgressView(Copy.Records.loading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    recordContent
                }
            case .failed:
                ContentUnavailableView(
                    Copy.Records.readFailureTitle,
                    systemImage: "exclamationmark.triangle",
                    description: Text(Copy.Records.readFailureBody)
                )
            default:
                recordContent
            }
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Records.navigationTitle)
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Copy.Records.search
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(patients, id: \.id) { patient in
                        Button {
                            patientID = patient.id
                        } label: {
                            if patient.id == patientID {
                                Label(patient.displayName, systemImage: "checkmark")
                            } else {
                                Text(patient.displayName)
                            }
                        }
                    }
                } label: {
                    Label(selectedPatientName, systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("m3.records.memberSwitcher")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Label(Copy.Records.filters, systemImage: filterSymbol)
                }
                .accessibilityIdentifier("m3.records.filters")
            }
        }
        .sheet(isPresented: $showFilters) {
            RecordFilterView(
                filter: $viewModel.filter,
                hospitals: viewModel.availableHospitals,
                doctors: viewModel.availableDoctors,
                diseases: viewModel.availableDiseases
            )
        }
        .fullScreenCover(item: $selectedOriginalRecord) { record in
            if let attachment = record.attachments
                .sorted(by: { $0.pageIndex < $1.pageIndex })
                .first {
                OriginalViewer(
                    record: record,
                    initialAttachmentID: attachment.id
                )
            }
        }
        .onAppear {
            viewModel.configure(context: modelContext)
            viewModel.reload(patientID: patientID)
        }
        .onChange(of: patientID) { _, newValue in
            viewModel.reload(patientID: newValue)
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.reload(patientID: patientID)
        }
        .onChange(of: viewModel.filter) { _, _ in
            viewModel.reload(patientID: patientID)
        }
        .onChange(of: refreshToken) { _, _ in
            viewModel.reload(patientID: patientID)
        }
        .accessibilityIdentifier("m3.records.library")
        #if DEBUG
        .screenshotReady(.records, when: !viewModel.records.isEmpty)
        #endif
    }

    @ViewBuilder
    private var recordContent: some View {
        if viewModel.records.isEmpty {
            ContentUnavailableView(
                viewModel.filter.isEmpty && viewModel.searchText.isEmpty
                    ? Copy.Records.empty
                    : Copy.Records.emptyFiltered,
                systemImage: "tray"
            )
        } else {
            List {
                if viewModel.pendingReviewCount > 0 {
                    pendingInboxRow
                }
                ForEach(viewModel.records, id: \.id) { record in
                    M4M5Card {
                        VStack(spacing: CT.Space.s2) {
                            NavigationLink {
                                RecordDetailView(record: record) {
                                    viewModel.reload(patientID: patientID)
                                }
                            } label: {
                                RecordListRow(record: record)
                            }
                            .accessibilityIdentifier(
                                "m3.records.row.\(record.id.uuidString)"
                            )
                            if !record.attachments.isEmpty {
                                Divider()
                                Button {
                                    selectedOriginalRecord = record
                                } label: {
                                    Label(
                                        Copy.viewOriginal,
                                        systemImage: "doc.text.magnifyingglass"
                                    )
                                    .font(CT.Font.subhead)
                                    .foregroundStyle(CT.Color.primary)
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: CT.Size.secondaryButtonHeight,
                                        alignment: .leading
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(
                                    "m3.records.original.\(record.id.uuidString)"
                                )
                            }
                        }
                    }
                    .listRowInsets(
                        EdgeInsets(
                            top: CT.Space.s2,
                            leading: CT.Space.s4,
                            bottom: CT.Space.s2,
                            trailing: CT.Space.s4
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(CT.Color.bgBase)
                }
                if viewModel.hasMore {
                    Button(Copy.Records.loadMore) {
                        viewModel.loadMore()
                    }
                    .frame(maxWidth: .infinity, minHeight: CT.Size.secondaryButtonHeight)
                    .accessibilityIdentifier("m3.records.loadMore")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var pendingInboxRow: some View {
        Button {
            if viewModel.filter.pendingReviewOnly {
                viewModel.clearPendingInbox(patientID: patientID)
            } else {
                viewModel.showPendingInbox(patientID: patientID)
            }
        } label: {
            HStack(spacing: CT.Space.s3) {
                Image(
                    systemName: viewModel.filter.pendingReviewOnly
                        ? "tray.full.fill"
                        : "tray.full"
                )
                .foregroundStyle(CT.Color.warning)
                VStack(alignment: .leading, spacing: CT.Space.s1) {
                    Text(Copy.Records.pendingInbox)
                        .font(CT.Font.headline)
                        .foregroundStyle(CT.Color.inkPrimary)
                    Text(
                        viewModel.filter.pendingReviewOnly
                            ? Copy.Records.pendingInboxShowing
                            : Copy.Records.pendingInboxCount(
                                viewModel.pendingReviewCount
                            )
                    )
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
                }
                Spacer()
                Image(
                    systemName: viewModel.filter.pendingReviewOnly
                        ? "xmark.circle.fill"
                        : "chevron.right"
                )
                .foregroundStyle(CT.Color.inkTertiary)
            }
            .frame(minHeight: CT.Size.secondaryButtonHeight)
        }
        .accessibilityIdentifier("m3.records.pendingInbox")
    }

    private var selectedPatientName: String {
        patients.first(where: { $0.id == patientID })?.displayName ?? Copy.Records.currentMember
    }

    private var filterSymbol: String {
        viewModel.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
    }
}

struct RecordListRowPresentation: Equatable {
    let summary: String?
    let showsAbnormalIndicator: Bool
    let statusTitle: String?
    let metadata: String
    let sourceTitle: String
    let hasAttachment: Bool

    init(record: MedicalRecord) {
        let trimmedSummary = record.summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        summary = trimmedSummary.isEmpty ? nil : trimmedSummary
        showsAbnormalIndicator = !record.abnormalFlags.isEmpty
        statusTitle = switch record.reviewStatus {
        case .pending: "待确认"
        case .needsInfo: "待补充"
        case .confirmed: nil
        }
        sourceTitle = switch record.sourceType {
        case .camera: "拍照"
        case .photo: "相册"
        case .file: "文件"
        case .manual: "手动录入"
        case .fixture: "演示原件"
        }
        let optionalValues: [String?] = [
            record.department,
            record.ageAtEvent.map { "\($0) 岁" },
            sourceTitle
        ]
        let values: [String] = optionalValues.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        metadata = values.joined(separator: " · ")
        hasAttachment = !record.attachments.isEmpty
    }
}

struct RecordListRow: View {
    let record: MedicalRecord

    var body: some View {
        let presentation = RecordListRowPresentation(record: record)
        HStack(alignment: .top, spacing: CT.Space.s3) {
            RecordThumbnail(record: record)
            VStack(alignment: .leading, spacing: CT.Space.s2) {
                HStack(alignment: .firstTextBaseline, spacing: CT.Space.s2) {
                    Text(record.displayTitle)
                        .font(CT.Font.headline)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .lineLimit(2)
                    Spacer(minLength: CT.Space.s1)
                    if record.isKeyRecord {
                        Image(systemName: "star.fill")
                            .foregroundStyle(CT.Color.warning)
                            .accessibilityLabel(Copy.Records.keyRecord)
                    }
                    if let statusTitle = presentation.statusTitle {
                        Text(statusTitle)
                            .font(CT.Font.label.weight(.semibold))
                            .foregroundStyle(
                                record.reviewStatus == .needsInfo
                                    ? CT.Color.dangerOnContainer
                                    : CT.Color.warningOnContainer
                            )
                            .padding(.horizontal, CT.Space.s2)
                            .padding(.vertical, CT.Space.s1)
                            .background(
                                record.reviewStatus == .needsInfo
                                    ? CT.Color.dangerContainer
                                    : CT.Color.warningContainer
                            )
                            .clipShape(Capsule())
                            .accessibilityIdentifier("m3.records.reviewStatus")
                    }
                }
                if let summary = presentation.summary {
                    HStack(alignment: .firstTextBaseline, spacing: CT.Space.s1) {
                        if presentation.showsAbnormalIndicator {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(CT.Color.danger)
                                .accessibilityLabel("有异常指标")
                        }
                        Text(summary)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkPrimary)
                            .lineLimit(2)
                    }
                    .accessibilityIdentifier("m3.records.summary")
                }
                Text(
                    "\(DateFormatter.m3ListDate.string(from: record.eventDate))"
                    + record.hospital.map { " · \($0)" }.orEmpty
                )
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
                .lineLimit(1)
                if !presentation.metadata.isEmpty {
                    Text(presentation.metadata)
                        .font(CT.Font.subhead)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .lineLimit(1)
                }
                let labels = ([record.primaryDisease].compactMap { $0 } + record.diseaseTags)
                if !labels.isEmpty {
                    Text(labels.joined(separator: " · "))
                        .font(CT.Font.caption)
                        .foregroundStyle(CT.Color.primary)
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: CT.Size.recordCardMinHeight, alignment: .top)
    }
}

private struct RecordThumbnail: View {
    let record: MedicalRecord
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("原件缩略图")
            } else {
                Image(systemName: record.type.symbolName)
                    .font(CT.Font.title3)
                    .foregroundStyle(record.type.semanticColor)
                    .background(record.type.semanticColor.opacity(CT.Opacity.subtle))
                    .accessibilityLabel(record.type.displayName)
            }
        }
        .frame(width: CT.Size.cardThumbnail, height: CT.Size.cardThumbnail)
        .background(CT.Color.bgInset)
        .clipShape(RoundedRectangle(cornerRadius: CT.Radius.thumbnail))
        .clipped()
        .task(id: record.attachments.first?.fileName) {
            image = await RecordThumbnailLoader.load(record.attachments.first)
        }
    }
}

private enum RecordThumbnailLoader {
    static func load(_ attachment: Attachment?) async -> UIImage? {
        guard let attachment, attachment.kind == .image else { return nil }
        return await Task.detached(priority: .utility) {
            guard let vault = try? CaptureVaultService(),
                  let url = try? vault.url(for: attachment.fileName),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(CT.Size.cardThumbnail * 3),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

private struct RecordFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: M3RecordFilter
    let hospitals: [String]
    let doctors: [String]
    let diseases: [String]

    @State private var draft = M3RecordFilter()
    @State private var useStartDate = false
    @State private var useEndDate = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var useAgeRange = false
    @State private var minimumAge = 0
    @State private var maximumAge = 130

    var body: some View {
        NavigationStack {
            Form {
                Section(Copy.Records.sort) {
                    Picker(Copy.Records.sort, selection: $draft.sort) {
                        ForEach(M3RecordSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                }
                Section(Copy.Records.reviewStatus) {
                    Toggle(
                        Copy.Records.pendingReviewOnly,
                        isOn: $draft.pendingReviewOnly
                    )
                    .tint(CT.Color.primary)
                }
                Section(Copy.Records.dateRange) {
                    Toggle(Copy.Records.startDate, isOn: $useStartDate)
                    if useStartDate {
                        DatePicker(
                            Copy.Records.fromDate,
                            selection: $startDate,
                            displayedComponents: .date
                        )
                    }
                    Toggle(Copy.Records.endDate, isOn: $useEndDate)
                    if useEndDate {
                        DatePicker(
                            Copy.Records.toDate,
                            selection: $endDate,
                            displayedComponents: .date
                        )
                    }
                }
                Section(Copy.Records.recordType) {
                    ForEach(RecordType.allCases, id: \.rawValue) { type in
                        MultiSelectRow(
                            title: type.displayName,
                            isSelected: draft.typeRawValues.contains(type.rawValue)
                        ) {
                            toggle(type.rawValue, in: &draft.typeRawValues)
                        }
                    }
                }
                if !diseases.isEmpty {
                    multiValueSection(
                        title: Copy.Records.disease,
                        values: diseases,
                        selection: $draft.diseaseValues
                    )
                }
                if !hospitals.isEmpty {
                    multiValueSection(
                        title: Copy.Records.hospital,
                        values: hospitals,
                        selection: $draft.hospitalValues
                    )
                }
                if !doctors.isEmpty {
                    multiValueSection(
                        title: Copy.Records.doctor,
                        values: doctors,
                        selection: $draft.doctorValues
                    )
                }
                Section(Copy.Records.age) {
                    Toggle(Copy.Records.filterByAge, isOn: $useAgeRange)
                    if useAgeRange {
                        Stepper("最小 \(minimumAge) 岁", value: $minimumAge, in: 0...130)
                        Stepper("最大 \(maximumAge) 岁", value: $maximumAge, in: 0...130)
                    }
                }
            }
            .navigationTitle(Copy.Records.filters)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Copy.Records.clearFilters) {
                        draft = M3RecordFilter()
                        useStartDate = false
                        useEndDate = false
                        useAgeRange = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Records.apply) {
                        draft.startDate = useStartDate
                            ? Calendar.current.startOfDay(for: startDate)
                            : nil
                        draft.endDate = useEndDate
                            ? Calendar.current.date(
                                byAdding: DateComponents(day: 1, second: -1),
                                to: Calendar.current.startOfDay(for: endDate)
                            )
                            : nil
                        draft.minimumAge = useAgeRange ? min(minimumAge, maximumAge) : nil
                        draft.maximumAge = useAgeRange ? max(minimumAge, maximumAge) : nil
                        filter = draft
                        dismiss()
                    }
                    .accessibilityIdentifier("m3.filters.apply")
                }
            }
        }
        .onAppear {
            draft = filter
            useStartDate = filter.startDate != nil
            useEndDate = filter.endDate != nil
            useAgeRange = filter.minimumAge != nil || filter.maximumAge != nil
            startDate = filter.startDate ?? Date()
            endDate = filter.endDate ?? Date()
            minimumAge = filter.minimumAge ?? 0
            maximumAge = filter.maximumAge ?? 130
        }
        .presentationCornerRadius(CT.Radius.sheet)
        .accessibilityIdentifier("m3.filters.sheet")
    }

    private func multiValueSection(
        title: String,
        values: [String],
        selection: Binding<Set<String>>
    ) -> some View {
        Section(title) {
            ForEach(values, id: \.self) { value in
                MultiSelectRow(title: value, isSelected: selection.wrappedValue.contains(value)) {
                    var copy = selection.wrappedValue
                    toggle(value, in: &copy)
                    selection.wrappedValue = copy
                }
            }
        }
    }

    private func toggle(_ value: String, in selection: inout Set<String>) {
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
    }
}

private struct MultiSelectRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(CT.Color.inkPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(CT.Color.primary)
                }
            }
            .frame(minHeight: CT.Size.secondaryButtonHeight)
        }
        .accessibilityValue(
            isSelected ? Copy.Common.selected : Copy.Common.notSelected
        )
    }
}

private extension DateFormatter {
    static let m3ListDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        return formatter
    }()
}
