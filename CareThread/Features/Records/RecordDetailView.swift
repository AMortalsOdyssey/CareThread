import SwiftData
import SwiftUI

struct RecordDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let record: MedicalRecord
    let onChanged: () -> Void

    @State private var showEdit = false
    @State private var showDeleteConfirmation = false
    @State private var selectedAttachment: Attachment?
    @State private var showError = false
    @State private var errorMessage = Copy.Records.localDataSafe

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s4) {
                header
                if !record.summary.isEmpty {
                    detailSection(title: Copy.Records.summary) {
                        Text(record.summary)
                            .font(CT.Font.bodyReading)
                            .foregroundStyle(CT.Color.inkPrimary)
                            .textSelection(.enabled)
                    }
                }
                if !record.measurements.isEmpty {
                    detailSection(title: Copy.Records.metrics) {
                        ForEach(record.measurements.sorted(by: { $0.displayName < $1.displayName }), id: \.id) { item in
                            HStack {
                                Text(item.displayName)
                                Spacer()
                                Text(metricValue(item))
                                    .font(CT.Font.valueMono)
                                    .foregroundStyle(metricColor(item.abnormalState))
                            }
                        }
                    }
                }
                if !record.structuredFields.isEmpty {
                    detailSection(title: Copy.Records.fields) {
                        ForEach(record.structuredFields) { field in
                            LabeledContent(field.key, value: field.value)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(field.key)
                                .accessibilityValue(field.value)
                                .accessibilityIdentifier(
                                    "m3.detail.field.\(field.id.uuidString)"
                                )
                        }
                    }
                }
                if !record.abnormalFlags.isEmpty {
                    detailSection(title: RecordEditCopy.abnormalFlags) {
                        Text(record.abnormalFlags.joined(separator: "、"))
                            .foregroundStyle(CT.Color.danger)
                            .textSelection(.enabled)
                    }
                }
                originalsSection
                relatedSection
                if let machine = record.machineExtraction {
                    detailSection(title: Copy.Records.machineSection) {
                        LabeledContent(Copy.Capture.title, value: machine.title)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Copy.Capture.title)
                            .accessibilityValue(machine.title)
                            .accessibilityIdentifier("m3.detail.machine.title")
                        LabeledContent(Copy.Capture.type, value: machine.type.displayName)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Copy.Capture.type)
                            .accessibilityValue(machine.type.displayName)
                            .accessibilityIdentifier("m3.detail.machine.type")
                        if let hospital = machine.hospital {
                            LabeledContent(Copy.Capture.hospital, value: hospital)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Copy.Capture.hospital)
                                .accessibilityValue(hospital)
                                .accessibilityIdentifier("m3.detail.machine.hospital")
                        }
                        Text(machine.summary)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkSecondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .contain)
                }
                settingsSection
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label(Copy.Records.delete, systemImage: "trash")
                }
                .buttonStyle(CTSecondaryButtonStyle())
                .tint(CT.Color.danger)
                .accessibilityIdentifier("m3.detail.delete")
            }
            .padding(CT.Space.s4)
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Records.detail)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(Copy.Records.edit) {
                    showEdit = true
                }
                .accessibilityIdentifier("m3.detail.edit")
            }
        }
        .sheet(isPresented: $showEdit) {
            RecordEditView(record: record) {
                onChanged()
            }
        }
        .fullScreenCover(item: $selectedAttachment) { attachment in
            OriginalViewer(record: record, initialAttachmentID: attachment.id)
        }
        .alert(Copy.Records.deleteTitle, isPresented: $showDeleteConfirmation) {
            Button(Copy.Records.delete, role: .destructive) {
                deleteRecord()
            }
            Button(Copy.Common.cancel, role: .cancel) {}
        } message: {
            Text(Copy.Records.deleteConfirm)
        }
        .alert(Copy.Common.operationFailed, isPresented: $showError) {
            Button(Copy.Common.acknowledge, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .accessibilityIdentifier("m3.detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            HStack(alignment: .top, spacing: CT.Space.s3) {
                Image(systemName: record.type.symbolName)
                    .font(CT.Font.title2)
                    .foregroundStyle(record.type.semanticColor)
                    .frame(width: CT.Size.leadingIcon, height: CT.Size.leadingIcon)
                VStack(alignment: .leading, spacing: CT.Space.s1) {
                    Text(record.displayTitle)
                        .font(CT.Font.title2)
                        .foregroundStyle(CT.Color.inkPrimary)
            Text(DateFormatter.m3DetailDate.string(from: record.eventDate))
                .font(CT.Font.subhead)
                .foregroundStyle(CT.Color.inkSecondary)
            Text(
                "\(record.eventDatePrecision.recordEditDisplayName) · "
                    + record.eventTimezoneIdentifier
            )
            .font(CT.Font.caption)
            .foregroundStyle(CT.Color.inkSecondary)
            Text(record.type.displayName)
                .font(CT.Font.caption)
                .foregroundStyle(record.type.semanticColor)
                }
            }
            if record.reviewStatus == .pending {
                Label(Copy.Common.pendingReview, systemImage: "exclamationmark.circle")
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var originalsSection: some View {
        detailSection(title: Copy.Records.originals) {
            if record.attachments.isEmpty {
                Label(Copy.Records.noOriginal, systemImage: "doc.text")
                    .font(CT.Font.subhead)
                    .foregroundStyle(CT.Color.inkSecondary)
            } else {
                Button {
                    selectedAttachment = record.attachments
                        .sorted(by: { $0.pageIndex < $1.pageIndex })
                        .first
                } label: {
                    Label(
                        Copy.viewOriginal,
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .buttonStyle(CTSecondaryButtonStyle())
                .accessibilityIdentifier("m3.detail.viewOriginal")
                ScrollView(.horizontal) {
                    HStack(spacing: CT.Space.s3) {
                        ForEach(record.attachments.sorted(by: { $0.pageIndex < $1.pageIndex }), id: \.id) { attachment in
                            Button {
                                selectedAttachment = attachment
                            } label: {
                                VStack(spacing: CT.Space.s1) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: CT.Radius.thumbnail)
                                            .fill(CT.Color.bgInset)
                                        Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "photo")
                                            .font(CT.Font.title3)
                                            .foregroundStyle(CT.Color.primary)
                                    }
                                    .frame(
                                        width: CT.Size.detailThumbnail,
                                        height: CT.Size.detailThumbnail
                                    )
                                    Text("\(Copy.Capture.page) \(attachment.pageIndex + 1)")
                                        .font(CT.Font.caption)
                                        .foregroundStyle(CT.Color.inkSecondary)
                                }
                            }
                            .accessibilityIdentifier("m3.detail.original.\(attachment.pageIndex)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var relatedSection: some View {
        detailSection(title: Copy.Records.related) {
            if let hospital = record.hospital {
                LabeledContent(Copy.Capture.hospital, value: hospital)
            }
            if let department = record.department {
                LabeledContent(Copy.Capture.department, value: department)
            }
            if let doctor = record.doctor {
                LabeledContent(Copy.Capture.doctor, value: doctor)
            }
            let diseases = ([record.primaryDisease].compactMap { $0 } + record.diseaseTags)
            if !diseases.isEmpty {
                LabeledContent(Copy.Records.disease, value: diseases.joined(separator: "、"))
            }
            if let age = record.ageAtEvent {
                LabeledContent(Copy.Records.age, value: "\(age) 岁")
            }
            LabeledContent(
                RecordEditCopy.reviewStatus,
                value: record.reviewStatus.recordEditDisplayName
            )
        }
    }

    private var settingsSection: some View {
        detailSection(title: Copy.Records.recordSettings) {
            Toggle(Copy.Records.keyRecord, isOn: Binding(
                get: { record.isKeyRecord },
                set: { updateToggle(key: "isKeyRecord", value: $0) }
            ))
            .tint(CT.Color.primary)
            .accessibilityIdentifier("m3.detail.keyRecord")
            Toggle(Copy.Records.inBrief, isOn: Binding(
                get: { record.inBrief },
                set: { updateToggle(key: "inBrief", value: $0) }
            ))
            .tint(CT.Color.primary)
            .accessibilityIdentifier("m3.detail.inBrief")
        }
    }

    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Text(title)
                    .font(CT.Font.headline)
                    .foregroundStyle(CT.Color.inkPrimary)
                content()
                    .font(CT.Font.body)
            }
        }
    }

    private func metricValue(_ measurement: LabMeasurement) -> String {
        if let value = measurement.numericValue {
            return "\(value.formatted()) \(measurement.unit)"
        }
        return [measurement.textualValue, measurement.unit]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func metricColor(_ state: LabFlag) -> Color {
        state == .none ? CT.Color.inkPrimary : CT.Color.danger
    }

    private func updateToggle(key: String, value: Bool) {
        var content = record.editableContent()
        if key == "isKeyRecord" {
            content.isKeyRecord = value
        } else {
            content.inBrief = value
        }
        do {
            _ = try ContentRevisionService(context: modelContext).edit(
                record,
                content: content,
                changedFieldKeys: [key],
                source: .manual,
                expectedRevision: record.contentRevision
            )
            onChanged()
        } catch ContentRevisionServiceError.noChanges {
            return
        } catch ContentRevisionServiceError.revisionConflict {
            errorMessage = Copy.Records.revisionConflict
            showError = true
        } catch {
            errorMessage = Copy.Records.localDataSafe
            showError = true
        }
    }

    private func deleteRecord() {
        do {
            try RecordRepository(
                context: modelContext,
                fileDeletion: try CaptureVaultService()
            ).delete(record)
            onChanged()
            dismiss()
        } catch {
            showError = true
        }
    }
}

private struct RecordEditDraft {
    var type: RecordType
    var title: String
    var summary: String
    var eventDate: Date
    var eventDatePrecision: EventDatePrecision
    var eventTimezoneIdentifier: String
    var hospital: String
    var department: String
    var doctor: String
    var diseases: String
    var ageEnabled: Bool
    var ageAtEvent: String
    var abnormalFlags: String
    var structuredFields: [RecordKeyValueDraft]
    var reviewStatus: ReviewStatus
    var isKeyRecord: Bool
    var inBrief: Bool
    var measurements: [RecordMeasurementDraft]
}

private struct RecordKeyValueDraft: Identifiable {
    let id: UUID
    var key: String
    var value: String

    init(
        id: UUID = UUID(),
        key: String = "",
        value: String = ""
    ) {
        self.id = id
        self.key = key
        self.value = value
    }
}

private struct RecordMeasurementDraft: Identifiable {
    let id: UUID
    var displayName: String
    var numericValue: String
    var textualValue: String
    var unit: String
    var referenceLow: String
    var referenceHigh: String
    var referenceText: String
    var abnormalState: LabFlag
    var confidence: Confidence
    var eventDate: Date

    init(
        id: UUID = UUID(),
        displayName: String = "",
        numericValue: String = "",
        textualValue: String = "",
        unit: String = "",
        referenceLow: String = "",
        referenceHigh: String = "",
        referenceText: String = "",
        abnormalState: LabFlag = .none,
        confidence: Confidence = .high,
        eventDate: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.numericValue = numericValue
        self.textualValue = textualValue
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.referenceText = referenceText
        self.abnormalState = abnormalState
        self.confidence = confidence
        self.eventDate = eventDate
    }

    init(_ measurement: LabMeasurement) {
        id = measurement.id
        displayName = measurement.displayName
        numericValue = measurement.numericValue?.formatted(
            .number.precision(.fractionLength(0...8))
        ) ?? ""
        textualValue = measurement.textualValue ?? ""
        unit = measurement.unit
        referenceLow = measurement.referenceLow?.formatted(
            .number.precision(.fractionLength(0...8))
        ) ?? ""
        referenceHigh = measurement.referenceHigh?.formatted(
            .number.precision(.fractionLength(0...8))
        ) ?? ""
        referenceText = measurement.referenceText ?? ""
        abnormalState = measurement.abnormalState
        confidence = measurement.confidence
        eventDate = measurement.eventDate
    }

    func edit() throws -> RecordMeasurementEdit {
        RecordMeasurementEdit(
            id: id,
            content: LabMeasurementEditableContent(
                displayName: displayName,
                numericValue: try optionalFiniteDouble(
                    numericValue,
                    field: RecordEditCopy.numericValue
                ),
                textualValue: MemberIdentity.optionalTrimmed(textualValue),
                unit: unit,
                referenceLow: try optionalFiniteDouble(
                    referenceLow,
                    field: RecordEditCopy.referenceLow
                ),
                referenceHigh: try optionalFiniteDouble(
                    referenceHigh,
                    field: RecordEditCopy.referenceHigh
                ),
                referenceText: MemberIdentity.optionalTrimmed(referenceText),
                abnormalState: abnormalState,
                confidence: confidence,
                eventDate: eventDate
            )
        )
    }

    private func optionalFiniteDouble(
        _ input: String,
        field: String
    ) throws -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(
            trimmed.replacingOccurrences(of: "，", with: ".")
                .replacingOccurrences(of: ",", with: ".")
        ), value.isFinite else {
            throw RecordEditDraftError.invalidNumber(field)
        }
        return value
    }
}

private enum RecordEditDraftError: Error {
    case invalidAge
    case invalidNumber(String)

    var message: String {
        switch self {
        case .invalidAge:
            RecordEditCopy.invalidAge
        case let .invalidNumber(field):
            "\(field)\(RecordEditCopy.invalidNumberSuffix)"
        }
    }
}

/// Shared business-field editor used by both display modes. The elder flow
/// deliberately reuses this mutation boundary so it cannot become a read-only
/// projection with different validation or revision semantics.
struct RecordEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let record: MedicalRecord
    let onSaved: () -> Void

    @State private var draft: RecordEditDraft
    @State private var baseRevision: Int
    @State private var showError = false
    @State private var errorMessage = Copy.Capture.saveFailure
    @FocusState private var numericFieldFocused: Bool

    init(record: MedicalRecord, onSaved: @escaping () -> Void) {
        self.record = record
        self.onSaved = onSaved
        _baseRevision = State(initialValue: record.contentRevision)
        _draft = State(
            initialValue: RecordEditDraft(
                type: record.type,
                title: record.title,
                summary: record.summary,
                eventDate: record.eventDate,
                eventDatePrecision: record.eventDatePrecision,
                eventTimezoneIdentifier: record.eventTimezoneIdentifier,
                hospital: record.hospital ?? "",
                department: record.department ?? "",
                doctor: record.doctor ?? "",
                diseases: ([record.primaryDisease].compactMap { $0 } + record.diseaseTags)
                    .joined(separator: "、"),
                ageEnabled: record.ageAtEvent != nil,
                ageAtEvent: record.ageAtEvent.map(String.init) ?? "",
                abnormalFlags: record.abnormalFlags.joined(separator: "、"),
                structuredFields: record.structuredFields.map {
                    RecordKeyValueDraft(id: $0.id, key: $0.key, value: $0.value)
                },
                reviewStatus: record.reviewStatus,
                isKeyRecord: record.isKeyRecord,
                inBrief: record.inBrief,
                measurements: record.measurements
                    .sorted(by: { $0.displayName < $1.displayName })
                    .map(RecordMeasurementDraft.init)
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Copy.Records.revisionNotice)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                }
                Section(Copy.Capture.type) {
                    Picker(Copy.Capture.type, selection: $draft.type) {
                        ForEach(RecordType.allCases, id: \.rawValue) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }
                Section(Copy.Capture.title) {
                    TextField(Copy.Capture.title, text: $draft.title)
                        .accessibilityIdentifier("m3.edit.title")
                }
                Section(Copy.Capture.date) {
                    DatePicker(
                        Copy.Capture.date,
                        selection: $draft.eventDate,
                        displayedComponents: draft.eventDatePrecision == .exactTime
                            ? [.date, .hourAndMinute]
                            : .date
                    )
                    Picker(
                        RecordEditCopy.datePrecision,
                        selection: $draft.eventDatePrecision
                    ) {
                        ForEach(EventDatePrecision.allCases, id: \.rawValue) {
                            Text($0.recordEditDisplayName).tag($0)
                        }
                    }
                    .accessibilityIdentifier("m3.edit.precision")
                    TextField(
                        RecordEditCopy.timezone,
                        text: $draft.eventTimezoneIdentifier
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("m3.edit.timezone")
                }
                Section(Copy.Records.related) {
                    TextField(Copy.Capture.hospital, text: $draft.hospital)
                        .accessibilityIdentifier("m3.edit.hospital")
                    TextField(Copy.Capture.department, text: $draft.department)
                        .accessibilityIdentifier("m3.edit.department")
                    TextField(Copy.Capture.doctor, text: $draft.doctor)
                        .accessibilityIdentifier("m3.edit.doctor")
                    TextField(Copy.Capture.diseases, text: $draft.diseases)
                        .accessibilityIdentifier("m3.edit.diseases")
                    Text(RecordEditCopy.listSeparatorHint)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                    Toggle(
                        RecordEditCopy.eventAge,
                        isOn: $draft.ageEnabled
                    )
                    .tint(CT.Color.primary)
                    .accessibilityIdentifier("m3.edit.ageEnabled")
                    if draft.ageEnabled {
                        TextField(
                            RecordEditCopy.eventAge,
                            text: $draft.ageAtEvent
                        )
                        .keyboardType(.numberPad)
                        .focused($numericFieldFocused)
                        .accessibilityIdentifier("m3.edit.age")
                    }
                }
                Section(Copy.Capture.summary) {
                    TextEditor(text: $draft.summary)
                        .frame(minHeight: CT.Size.recordCardMinHeight)
                        .accessibilityIdentifier("m3.edit.summary")
                }
                Section(RecordEditCopy.reviewAndFlags) {
                    Picker(
                        RecordEditCopy.reviewStatus,
                        selection: $draft.reviewStatus
                    ) {
                        ForEach(ReviewStatus.allCases, id: \.rawValue) {
                            Text($0.recordEditDisplayName).tag($0)
                        }
                    }
                    .accessibilityIdentifier("m3.edit.reviewStatus")
                    TextField(
                        RecordEditCopy.abnormalFlags,
                        text: $draft.abnormalFlags
                    )
                    .accessibilityIdentifier("m3.edit.abnormalFlags")
                    Text(RecordEditCopy.listSeparatorHint)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                    Toggle(Copy.Records.keyRecord, isOn: $draft.isKeyRecord)
                        .tint(CT.Color.primary)
                        .accessibilityIdentifier("m3.edit.keyRecord")
                    Toggle(Copy.Records.inBrief, isOn: $draft.inBrief)
                        .tint(CT.Color.primary)
                        .accessibilityIdentifier("m3.edit.inBrief")
                }
                structuredFieldsSection
                measurementsSection
                if let machine = record.machineExtraction {
                    Section(Copy.Records.machineSection) {
                        LabeledContent(Copy.Capture.title, value: machine.title)
                        Text(machine.summary)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkSecondary)
                    }
                }
                Section {
                    Text(RecordEditCopy.immutableSourceNotice)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                }
            }
            .navigationTitle(Copy.Records.editTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Records.save) {
                        save()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("m3.edit.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(Copy.Common.done) {
                        numericFieldFocused = false
                    }
                    .accessibilityIdentifier("m3.edit.keyboardDone")
                }
            }
        }
        .alert(Copy.Common.saveFailed, isPresented: $showError) {
            Button(Copy.Common.acknowledge, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .presentationCornerRadius(CT.Radius.sheet)
        .accessibilityIdentifier("m3.edit.sheet")
    }

    private var structuredFieldsSection: some View {
        Section(RecordEditCopy.structuredFields) {
            ForEach($draft.structuredFields) { $field in
                VStack(alignment: .leading, spacing: CT.Space.s2) {
                    TextField(RecordEditCopy.fieldName, text: $field.key)
                        .accessibilityIdentifier(
                            "m3.edit.field.key.\(field.id.uuidString)"
                        )
                    TextField(
                        RecordEditCopy.fieldValue,
                        text: $field.value,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .accessibilityIdentifier(
                        "m3.edit.field.value.\(field.id.uuidString)"
                    )
                    Button(
                        RecordEditCopy.deleteField,
                        role: .destructive
                    ) {
                        draft.structuredFields.removeAll {
                            $0.id == field.id
                        }
                    }
                    .accessibilityIdentifier(
                        "m3.edit.field.delete.\(field.id.uuidString)"
                    )
                }
            }
            Button {
                draft.structuredFields.append(RecordKeyValueDraft())
            } label: {
                Label(RecordEditCopy.addField, systemImage: "plus.circle")
            }
            .accessibilityIdentifier("m3.edit.addField")
        }
    }

    private var measurementsSection: some View {
        Section(RecordEditCopy.measurements) {
            ForEach($draft.measurements) { $measurement in
                VStack(alignment: .leading, spacing: CT.Space.s3) {
                    TextField(
                        RecordEditCopy.measurementName,
                        text: $measurement.displayName
                    )
                    .font(CT.Font.headline)
                    .accessibilityIdentifier(
                        "m3.edit.measurement.name.\(measurement.id.uuidString)"
                    )
                    HStack(spacing: CT.Space.s3) {
                        TextField(
                            RecordEditCopy.numericValue,
                            text: $measurement.numericValue
                        )
                        .keyboardType(.decimalPad)
                        .focused($numericFieldFocused)
                        .accessibilityIdentifier(
                            "m3.edit.measurement.numeric.\(measurement.id.uuidString)"
                        )
                        TextField(
                            RecordEditCopy.unit,
                            text: $measurement.unit
                        )
                        .accessibilityIdentifier(
                            "m3.edit.measurement.unit.\(measurement.id.uuidString)"
                        )
                    }
                    TextField(
                        RecordEditCopy.textValue,
                        text: $measurement.textualValue
                    )
                    .accessibilityIdentifier(
                        "m3.edit.measurement.text.\(measurement.id.uuidString)"
                    )
                    HStack(spacing: CT.Space.s3) {
                        TextField(
                            RecordEditCopy.referenceLow,
                            text: $measurement.referenceLow
                        )
                        .keyboardType(.decimalPad)
                        .focused($numericFieldFocused)
                        TextField(
                            RecordEditCopy.referenceHigh,
                            text: $measurement.referenceHigh
                        )
                        .keyboardType(.decimalPad)
                        .focused($numericFieldFocused)
                    }
                    TextField(
                        RecordEditCopy.referenceText,
                        text: $measurement.referenceText
                    )
                    Picker(
                        RecordEditCopy.flag,
                        selection: $measurement.abnormalState
                    ) {
                        ForEach(LabFlag.recordEditCases, id: \.rawValue) {
                            Text($0.recordEditDisplayName).tag($0)
                        }
                    }
                    Picker(
                        RecordEditCopy.confidence,
                        selection: $measurement.confidence
                    ) {
                        ForEach(Confidence.recordEditCases, id: \.rawValue) {
                            Text($0.recordEditDisplayName).tag($0)
                        }
                    }
                    DatePicker(
                        RecordEditCopy.measurementDate,
                        selection: $measurement.eventDate,
                        displayedComponents: .date
                    )
                    Button(
                        RecordEditCopy.deleteMeasurement,
                        role: .destructive
                    ) {
                        draft.measurements.removeAll {
                            $0.id == measurement.id
                        }
                    }
                    .accessibilityIdentifier(
                        "m3.edit.measurement.delete.\(measurement.id.uuidString)"
                    )
                }
                .padding(.vertical, CT.Space.s2)
            }
            Button {
                draft.measurements.append(
                    RecordMeasurementDraft(eventDate: draft.eventDate)
                )
            } label: {
                Label(
                    RecordEditCopy.addMeasurement,
                    systemImage: "plus.circle"
                )
            }
            .accessibilityIdentifier("m3.edit.addMeasurement")
        }
    }

    private func save() {
        do {
            var content = record.editableContent()
            content.type = draft.type
            content.title = draft.title
            content.summary = draft.summary
            content.eventDate = draft.eventDate
            content.eventDatePrecision = draft.eventDatePrecision
            content.eventTimezoneIdentifier = draft.eventTimezoneIdentifier
            content.hospital = MemberIdentity.optionalTrimmed(draft.hospital)
            content.department = MemberIdentity.optionalTrimmed(draft.department)
            content.doctor = MemberIdentity.optionalTrimmed(draft.doctor)
            if draft.ageEnabled {
                guard let age = Int(
                    draft.ageAtEvent.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                ), (0...130).contains(age) else {
                    throw RecordEditDraftError.invalidAge
                }
                content.ageAtEvent = age
            } else {
                content.ageAtEvent = nil
            }
            content.abnormalFlags = splitList(draft.abnormalFlags)
            content.structuredFields = draft.structuredFields.map {
                KeyValueItem(id: $0.id, key: $0.key, value: $0.value)
            }
            content.reviewStatus = draft.reviewStatus
            content.isKeyRecord = draft.isKeyRecord
            content.inBrief = draft.inBrief
            let diseases = draft.diseases
                .components(separatedBy: CharacterSet(charactersIn: "、,，;；"))
                .compactMap(MemberIdentity.optionalTrimmed)
            content.primaryDisease = diseases.first
            let measurements = try draft.measurements.map { try $0.edit() }
            _ = try RecordAggregateEditService(context: modelContext).save(
                record: record,
                content: content,
                diseaseValues: diseases,
                measurementEdits: measurements,
                changedFieldKeys: [
                    "type", "title", "summary", "eventDate", "hospital",
                    "department", "doctor", "primaryDisease"
                ],
                expectedRevision: baseRevision
            )
            onSaved()
            dismiss()
        } catch RecordAggregateEditError.noChanges {
            dismiss()
        } catch RecordAggregateEditError.revisionConflict {
            errorMessage = Copy.Records.revisionConflict
            showError = true
        } catch let error as RecordEditDraftError {
            errorMessage = error.message
            showError = true
        } catch let error as RecordAggregateEditError {
            errorMessage = RecordEditCopy.message(for: error)
            showError = true
        } catch {
            errorMessage = Copy.Capture.saveFailure
            showError = true
        }
    }

    private func splitList(_ value: String) -> [String] {
        value.components(
            separatedBy: CharacterSet(charactersIn: "、,，;；\n")
        )
        .compactMap(MemberIdentity.optionalTrimmed)
    }
}

private enum RecordEditCopy {
    static let datePrecision = "日期精度"
    static let timezone = "时区标识（例如 Asia/Shanghai）"
    static let eventAge = "发生时年龄"
    static let reviewAndFlags = "确认状态与标记"
    static let reviewStatus = "确认状态"
    static let abnormalFlags = "异常标记"
    static let listSeparatorHint = "多个内容可用顿号、逗号、分号或换行分隔。"
    static let structuredFields = "结构化字段"
    static let fieldName = "字段名"
    static let fieldValue = "字段值"
    static let addField = "添加字段"
    static let deleteField = "删除这个字段"
    static let measurements = "检验指标"
    static let measurementName = "指标名称"
    static let numericValue = "数值"
    static let textValue = "文字结果"
    static let unit = "单位"
    static let referenceLow = "参考下限"
    static let referenceHigh = "参考上限"
    static let referenceText = "参考范围文字"
    static let flag = "结果标记"
    static let confidence = "识别可信度"
    static let measurementDate = "指标日期"
    static let addMeasurement = "添加检验指标"
    static let deleteMeasurement = "删除这个指标"
    static let immutableSourceNotice =
        "成员归属、原件、文件校验值、原始识别文字和机器提取结果不会在这里改写。"
    static let invalidAge = "年龄应为 0 到 130 的整数。"
    static let invalidNumberSuffix = "应填写有限数字，或留空。"
    static let invalidTimezone = "请填写有效的时区标识。"
    static let invalidField = "请检查必填项、数值范围和重复字段名。"

    static func message(for error: RecordAggregateEditError) -> String {
        switch error {
        case let .invalidValue(field)
            where field == "eventDate" || field == "eventTimezoneIdentifier":
            invalidTimezone
        case .invalidValue:
            invalidField
        case .immutableField:
            "系统字段不可修改；本地资料没有被覆盖。"
        case .crossPatientScope:
            "检测到其他成员的指标，已阻止保存。"
        case .noChanges:
            ""
        case .revisionConflict:
            Copy.Records.revisionConflict
        case .payloadEncodingFailed, .invalidGraph, .databaseSaveFailed:
            Copy.Records.localDataSafe
        }
    }
}

private extension EventDatePrecision {
    var recordEditDisplayName: String {
        switch self {
        case .exactTime: "精确到时间"
        case .day: "精确到日"
        case .month: "精确到月"
        case .year: "精确到年"
        case .unknown: "日期不确定"
        }
    }
}

private extension ReviewStatus {
    var recordEditDisplayName: String {
        switch self {
        case .pending: "待确认"
        case .confirmed: "已确认"
        case .needsInfo: "信息待补充"
        }
    }
}

private extension LabFlag {
    static let recordEditCases: [LabFlag] = [
        .none, .low, .high, .positive
    ]

    var recordEditDisplayName: String {
        switch self {
        case .none: "无"
        case .low: "偏低"
        case .high: "偏高"
        case .positive: "阳性"
        }
    }
}

private extension Confidence {
    static let recordEditCases: [Confidence] = [.high, .low]

    var recordEditDisplayName: String {
        switch self {
        case .high: "高"
        case .low: "低"
        }
    }
}

private extension DateFormatter {
    static let m3DetailDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .long
        return formatter
    }()
}
