import SwiftData
import SwiftUI

struct ElderRecordsView: View {
    @Query private var records: [MedicalRecord]
    let patientID: UUID
    let refreshToken: Int

    init(patientID: UUID, refreshToken: Int = 0) {
        self.patientID = patientID
        self.refreshToken = refreshToken
        _records = Query(
            filter: #Predicate<MedicalRecord> {
                $0.patientId == patientID
            },
            sort: [
                SortDescriptor(\.eventDate, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
    }

    var body: some View {
        ScrollView {
            if records.isEmpty {
                VStack(spacing: CT.Space.s4) {
                    Image(systemName: "tray")
                        .font(.system(size: CT.Size.elderEmptySymbol))
                        .foregroundStyle(CT.Color.inkTertiary)
                    Text(Copy.Elder.noRecords)
                        .font(CT.Font.elderBody)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(8)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .accessibilityIdentifier("elder.records.empty")
            } else {
                LazyVStack(alignment: .leading, spacing: CT.Space.s4) {
                    ForEach(monthGroups, id: \.month) { group in
                        Text(group.month)
                            .font(CT.Font.elderTitle2)
                            .foregroundStyle(CT.Color.inkPrimary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.records, id: \.id) { record in
                            NavigationLink {
                                ElderRecordDetailView(record: record)
                            } label: {
                                ElderRecordCard {
                                    VStack(
                                        alignment: .leading,
                                        spacing: CT.Space.s2
                                    ) {
                                        Text(record.displayTitle)
                                            .font(CT.Font.elderHeadline)
                                            .foregroundStyle(
                                                CT.Color.inkPrimary
                                            )
                                        Text(
                                            Self.day.string(
                                                from: record.eventDate
                                            )
                                        )
                                        .font(CT.Font.elderFootnote)
                                        .foregroundStyle(
                                            CT.Color.inkSecondary
                                        )
                                        Text(
                                            record.reviewStatus == .pending
                                                ? Copy.Elder.recordPending
                                                : record.summary.isEmpty
                                                    ? Copy.Elder.recordSummaryEmpty
                                                    : record.summary
                                        )
                                        .font(CT.Font.elderBody)
                                        .foregroundStyle(
                                            CT.Color.inkPrimary
                                        )
                                        .lineLimit(2)
                                        .lineSpacing(8)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                "elder.records.card.\(record.id.uuidString)"
                            )
                        }
                    }
                }
                .padding(CT.Space.elderScreen)
            }
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Elder.records)
        .id(refreshToken)
        .accessibilityIdentifier("elder.records")
        #if DEBUG
        .screenshotReady(.elderRecords, when: !records.isEmpty)
        #endif
    }

    private var monthGroups: [(month: String, records: [MedicalRecord])] {
        var order: [String] = []
        var grouped: [String: [MedicalRecord]] = [:]
        for record in records {
            let month = Self.month.string(from: record.eventDate)
            if grouped[month] == nil {
                order.append(month)
            }
            grouped[month, default: []].append(record)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = CTDate.calendar
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    fileprivate static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = CTDate.calendar
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

struct ElderRecordDetailView: View {
    let record: MedicalRecord
    @State private var showOriginal = false
    @State private var showEdit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s5) {
                Text(
                    record.summary.isEmpty
                        ? Copy.Elder.recordSummaryEmpty
                        : record.summary
                )
                .font(CT.Font.elderBody)
                .foregroundStyle(CT.Color.inkPrimary)
                .lineSpacing(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                ElderRecordCard {
                    VStack(alignment: .leading, spacing: CT.Space.s3) {
                        Text(Copy.Elder.recordDateHospital)
                            .font(CT.Font.elderHeadline)
                        Text(
                            ElderRecordsView.day.string(
                                from: record.eventDate
                            )
                        )
                        .font(CT.Font.elderBody)
                        Text(record.hospital ?? Copy.Elder.hospitalMissing)
                            .font(CT.Font.elderBody)
                    }
                    .foregroundStyle(CT.Color.inkPrimary)
                }
                Button {
                    showEdit = true
                } label: {
                    Label(
                        Copy.Elder.editRecord,
                        systemImage: "square.and.pencil"
                    )
                }
                .buttonStyle(ElderSecondaryButtonStyle())
                .accessibilityIdentifier("elder.record.edit")
                if record.reviewStatus == .pending {
                    Text(Copy.Elder.recordPending)
                        .font(CT.Font.elderSubhead)
                        .foregroundStyle(CT.Color.warningOnContainer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(CT.Space.s4)
                        .background(CT.Color.warningContainer)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: CT.Radius.elderCard,
                                style: .continuous
                            )
                        )
                }
                Button {
                    showOriginal = true
                } label: {
                    Label(
                        Copy.Elder.viewOriginal,
                        systemImage: "doc.richtext"
                    )
                }
                .buttonStyle(ElderSecondaryButtonStyle())
                .disabled(record.attachments.isEmpty)
                .accessibilityValue(
                    "\(record.attachments.count) \(Copy.Capture.page)"
                )
                .accessibilityIdentifier("elder.record.original")
            }
            .padding(CT.Space.elderScreen)
        }
        .background(CT.Color.bgBase)
        .navigationTitle(record.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOriginal) {
            if let attachment = record.attachments
                .sorted(by: { $0.pageIndex < $1.pageIndex })
                .first {
                ElderOriginalViewer(
                    record: record,
                    initialAttachmentID: attachment.id
                )
            }
        }
        .sheet(isPresented: $showEdit) {
            RecordEditView(record: record) {}
                .dynamicTypeSize(...ElderDynamicTypePolicy.maximum)
        }
        .accessibilityIdentifier("elder.record.detail")
    }
}

struct ElderOriginalViewer: View {
    @Environment(\.dismiss) private var dismiss
    let record: MedicalRecord
    @State private var selectedAttachmentID: UUID

    init(record: MedicalRecord, initialAttachmentID: UUID) {
        self.record = record
        _selectedAttachmentID = State(initialValue: initialAttachmentID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: CT.Space.s3) {
                if let attachment = selectedAttachment,
                   let vault = try? CaptureVaultService(),
                   let url = try? vault.url(
                       for: attachment.originalFileName
                           ?? attachment.fileName
                   ) {
                    QuickLookURLView(url: url)
                        .background(CT.Color.bgBase)
                } else {
                    VStack(spacing: CT.Space.s5) {
                        ContentUnavailableView(
                            Copy.Records.missingOriginal,
                            systemImage: "doc.questionmark",
                            description: Text(
                                Copy.Records.missingOriginalGuidance
                            )
                        )
                        NavigationLink {
                            BackupRestoreView(patientID: record.patientId)
                        } label: {
                            Label(
                                Copy.Records.recoverOriginal,
                                systemImage:
                                    "externaldrive.badge.timemachine"
                            )
                        }
                        .buttonStyle(ElderPrimaryButtonStyle())
                        .accessibilityIdentifier(
                            "elder.original.recoverOriginal"
                        )
                    }
                    .padding(CT.Space.elderScreen)
                }
                if attachments.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: CT.Space.s3) {
                            ForEach(attachments, id: \.id) { attachment in
                                Button("第 \(attachment.pageIndex + 1) 页") {
                                    selectedAttachmentID = attachment.id
                                }
                                .buttonStyle(ElderSecondaryButtonStyle())
                                .frame(minWidth: 130)
                            }
                        }
                        .padding(.horizontal, CT.Space.elderScreen)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle(Copy.Elder.viewOriginal)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.done) {
                        dismiss()
                    }
                    .font(CT.Font.elderSubhead)
                    .frame(minHeight: CT.Size.elderTouchTarget)
                }
            }
        }
        .dynamicTypeSize(...ElderDynamicTypePolicy.maximum)
        .accessibilityIdentifier("elder.original")
    }

    private var attachments: [Attachment] {
        record.attachments.sorted {
            $0.pageIndex < $1.pageIndex
        }
    }

    private var selectedAttachment: Attachment? {
        attachments.first(where: { $0.id == selectedAttachmentID })
            ?? attachments.first
    }
}
