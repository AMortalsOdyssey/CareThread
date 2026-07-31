import SwiftData
import SwiftUI

struct CaptureConfirmationView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var controller: M3CaptureFlowController
    let patients: [Patient]
    let onSwitchMember: (UUID) -> Void
    let onSaved: () -> Void
    let onSaveDraft: () -> Void
    var onMedicationSuggestion: (MedicationHint) -> Void = { _ in }
    var onFollowUpSuggestion: (FollowUpHint) -> Void = { _ in }

    @State private var showOverrideConfirmation = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = Copy.Capture.saveFailure
    @State private var explicitlySwitchedPatientID: UUID?
    @State private var selectedOriginalPage: M3CapturePageAsset?
    @FocusState private var textInputFocused: Bool

    var body: some View {
        Group {
            if controller.confirmations.isEmpty {
                ProgressView()
            } else {
                confirmationForm
            }
        }
        .navigationTitle(Copy.Capture.confirmation)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(Copy.Capture.saveDraft) {
                    textInputFocused = false
                    onSaveDraft()
                }
                .accessibilityIdentifier("m3.confirm.saveDraft")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(Copy.Common.done) {
                    textInputFocused = false
                }
                .accessibilityIdentifier("m3.confirm.keyboardDone")
            }
        }
        .sheet(item: $selectedOriginalPage) { page in
            CaptureConfirmationOriginalPreview(page: page)
        }
        .alert(Copy.Capture.overrideConfirmTitle, isPresented: $showOverrideConfirmation) {
            Button(Copy.Capture.confirmOverride, role: .destructive) {
                saveCurrent(
                    decision: .acceptedAfterNameRecognitionOverride,
                    assignedPatientID: controller.frozenPatientID,
                    overrideReason: Copy.Capture.overrideReason
                )
            }
            Button(Copy.Common.cancel, role: .cancel) {}
        } message: {
            Text(Copy.Capture.overrideConfirmBody)
        }
        .alert(Copy.Capture.saveFailure, isPresented: $showSaveError) {
            Button(Copy.Common.acknowledge, role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
        .onAppear {
            prepareEditableCollections()
        }
        .onChange(of: controller.confirmations.first?.id) { _, _ in
            prepareEditableCollections()
        }
    }

    private var currentBinding: Binding<M3ConfirmationDocument> {
        Binding(
            get: { controller.confirmations[0] },
            set: { controller.confirmations[0] = $0 }
        )
    }

    private var current: M3ConfirmationDocument {
        controller.confirmations[0]
    }

    private var confirmationForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s4) {
                HStack {
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Text(Copy.Capture.frozenMember)
                            .font(CT.Font.footnote)
                            .foregroundStyle(CT.Color.inkSecondary)
                            .accessibilityIdentifier("m3.confirmation")
                        Text(controller.frozenPatientName)
                            .font(CT.Font.title3)
                            .foregroundStyle(CT.Color.inkPrimary)
                    }
                    Spacer()
                    Text(
                        Copy.Capture.documentProgress(
                            controller.completedRecordCount + 1,
                            controller.completedRecordCount + controller.confirmations.count
                        )
                    )
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .accessibilityIdentifier("m3.confirm.progress")
                }
                .padding(CT.Space.s4)
                .background(CT.Color.bgInset)
                .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card))
                .accessibilityElement(children: .contain)

                Text(Copy.Capture.requiredFieldsHint)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)

                if hasZeroOCRText {
                    CTStatusBanner(
                        title: Copy.Capture.ocrEmptyTitle,
                        message: Copy.Capture.ocrEmptyBody,
                        tone: .warning
                    )
                    .accessibilityIdentifier("m3.confirm.ocrEmpty")
                }

                if !current.pages.isEmpty {
                    attachmentStrip
                }

                nameEvidenceGate

                if current.sourceType != .manual {
                    Button(Copy.Capture.adoptAll) {
                        adoptAllMachineValues()
                    }
                    .buttonStyle(CTSecondaryButtonStyle())
                    .accessibilityIdentifier("m3.confirm.adoptAll")
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.type,
                    machineValue: current.machine.type.displayName
                ) {
                    Picker(Copy.Capture.type, selection: currentBinding.type) {
                        ForEach(RecordType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("m3.confirm.type")
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.title,
                    machineValue: current.machine.title
                ) {
                    TextField(Copy.Capture.title, text: currentBinding.title)
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                        .accessibilityIdentifier("m3.confirm.title")
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.date,
                    machineValue: current.machine.eventDate.map(DateFormatter.m3Date.string)
                        ?? Copy.Common.notRecognized
                ) {
                    DatePicker(
                        Copy.Capture.date,
                        selection: currentBinding.eventDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .accessibilityIdentifier("m3.confirm.date")
                }

                if hasFutureEventDate {
                    CTStatusBanner(
                        title: Copy.Capture.futureDateTitle,
                        message: Copy.Capture.futureDateBody,
                        tone: .warning
                    )
                    .accessibilityIdentifier("m3.confirm.futureDateWarning")
                }

                if controller.frozenPatientBirthDate == nil {
                    manualAgeField
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.hospital,
                    machineValue: current.machine.hospital ?? Copy.Common.notRecognized
                ) {
                    TextField(Copy.Capture.hospital, text: currentBinding.hospital)
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                        .accessibilityIdentifier("m3.confirm.hospital")
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.department,
                    machineValue: current.machine.department ?? Copy.Common.notRecognized
                ) {
                    TextField(Copy.Capture.department, text: currentBinding.department)
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                        .accessibilityIdentifier("m3.confirm.department")
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.doctor,
                    machineValue: Copy.Common.notRecognized
                ) {
                    TextField(Copy.Capture.doctor, text: currentBinding.doctor)
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                        .accessibilityIdentifier("m3.confirm.doctor")
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.diseases,
                    machineValue: current.machine.abnormalFlags.joined(separator: "、")
                ) {
                    TextField(Copy.Capture.diseases, text: currentBinding.diseases)
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                        .accessibilityIdentifier("m3.confirm.diseases")
                }

                M3ConfirmFieldRow(
                    title: Copy.Capture.summary,
                    machineValue: current.machine.summary
                ) {
                    TextEditor(text: currentBinding.summary)
                        .font(CT.Font.body)
                        .frame(minHeight: CT.Size.recordCardMinHeight)
                        .padding(CT.Space.s2)
                        .background(CT.Color.bgInset)
                        .clipShape(RoundedRectangle(cornerRadius: CT.Radius.input))
                        .focused($textInputFocused)
                        .accessibilityIdentifier("m3.confirm.summary")
                }

                if !currentBinding.wrappedValue.structuredFields.isEmpty {
                    confirmationFields
                }
                abnormalEditor
                if current.type == .lab || !currentBinding.wrappedValue.labDrafts.isEmpty {
                    confirmationMetrics
                }
                if !current.machine.medicationHints.isEmpty
                    || !current.machine.followUpHints.isEmpty {
                    linkedSuggestions
                }

                if current.sourceType != .manual {
                    CTCard {
                        VStack(alignment: .leading, spacing: CT.Space.s2) {
                            Label(
                                "\(current.pages.count) \(Copy.Capture.page)",
                                systemImage: "doc.on.doc"
                            )
                            .font(CT.Font.headline)
                            Text(Copy.Capture.userBoundary)
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.inkSecondary)
                        }
                    }
                }

            }
            .padding(CT.Space.s4)
        }
        .safeAreaInset(edge: .bottom) {
            if canSaveDirectly {
                saveButton
                    .padding(.horizontal, CT.Space.s4)
                    .padding(.vertical, CT.Space.s2)
                    .background(CT.Color.bgBase)
            }
        }
    }

    private var hasZeroOCRText: Bool {
        guard current.sourceType != .manual else { return false }
        return current.pages.allSatisfy {
            ($0.ocrText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private var hasFutureEventDate: Bool {
        M3ConfirmationPolicy.isFutureEventDate(current.eventDate)
    }

    private var canSaveContent: Bool {
        let needsManualAge = controller.frozenPatientBirthDate == nil
        let ageIsValid = !needsManualAge
            || M3ConfirmationPolicy.isManualAgeValid(current.manualAgeText)
        return ageIsValid
            && !current.labDrafts.contains(where: \.hasValidationError)
    }

    private var saveButton: some View {
        Button(Copy.Capture.save) {
            let decision: AssignmentDecision =
                current.evidence?.outcome == .match
                ? .acceptedMatch
                : .acceptedWithoutNameEvidence
            saveCurrent(
                decision: decision,
                assignedPatientID: controller.frozenPatientID
            )
        }
        .buttonStyle(CTPrimaryButtonStyle())
        .disabled(!canSaveContent)
        .accessibilityHint(Copy.Capture.requiredFieldsHint)
        .accessibilityIdentifier("m3.confirm.save")
    }

    private var attachmentStrip: some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Text(Copy.Capture.attachmentStrip)
                    .font(CT.Font.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: CT.Space.s2) {
                        ForEach(Array(current.pages.enumerated()), id: \.element.id) {
                            index,
                            page in
                            Button {
                                selectedOriginalPage = page
                            } label: {
                                CaptureConfirmationThumbnail(page: page)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Copy.Capture.attachmentPage(index + 1))
                            .accessibilityIdentifier("m3.confirm.attachment.\(index)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var manualAgeField: some View {
        M3ConfirmFieldRow(
            title: Copy.Capture.ageAtEvent,
            machineValue: ""
        ) {
            VStack(alignment: .leading, spacing: CT.Space.s2) {
                TextField(
                    Copy.Capture.ageAtEventHint,
                    text: currentBinding.manualAgeText
                )
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .focused($textInputFocused)
                .accessibilityIdentifier("m3.confirm.manualAge")
                if !M3ConfirmationPolicy.isManualAgeValid(current.manualAgeText) {
                    Text(Copy.Capture.ageAtEventInvalid)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.warning)
                        .accessibilityIdentifier("m3.confirm.manualAgeError")
                }
            }
        }
    }

    @ViewBuilder
    private var nameEvidenceGate: some View {
        if current.sourceType == .manual {
            EmptyView()
        } else {
            switch current.evidence?.outcome {
            case .match:
                CTStatusBanner(
                    title: Copy.Capture.matchedNameTitle,
                    message: Copy.Capture.matchedNameBody,
                    tone: .information
                )
            case .noEvidence, .none:
                CTStatusBanner(
                    title: Copy.Capture.verifyOwnerTitle,
                    message: Copy.Capture.noNameEvidence,
                    tone: .warning
                )
            case .mismatch:
                CTStatusBanner(
                    title: Copy.Capture.mismatchTitle,
                    message: Copy.Capture.mismatchBody,
                    tone: .danger
                )
                mismatchActions
            case .ambiguous:
                CTStatusBanner(
                    title: Copy.Capture.ambiguousTitle,
                    message: Copy.Capture.ambiguousBody,
                    tone: .danger
                )
                ambiguousActions
            }
        }
    }

    private var mismatchActions: some View {
        VStack(spacing: CT.Space.s3) {
            if let matching = matchingPatient {
                Button(
                    explicitlySwitchedPatientID == matching.id
                        ? Copy.Capture.saveAfterSwitch(matching.displayName)
                        : Copy.Capture.switchMemberAction(matching.displayName)
                ) {
                    if explicitlySwitchedPatientID == matching.id {
                        saveCurrent(
                            decision: .switchedMember,
                            assignedPatientID: matching.id
                        )
                    } else {
                        onSwitchMember(matching.id)
                        explicitlySwitchedPatientID = matching.id
                    }
                }
                .buttonStyle(CTPrimaryButtonStyle())
                .accessibilityIdentifier("m3.confirm.switchMember")
            }
            Button(Copy.Capture.nameRecognitionWrong) {
                showOverrideConfirmation = true
            }
            .buttonStyle(CTSecondaryButtonStyle())
            .accessibilityIdentifier("m3.confirm.nameOverride")
        }
    }

    private var ambiguousActions: some View {
        VStack(spacing: CT.Space.s3) {
            Button(Copy.Capture.returnToGrouping) {
                controller.confirmations = []
                controller.groupingConfirmed = false
                controller.phase = .workbench
            }
            .buttonStyle(CTPrimaryButtonStyle())
            .accessibilityIdentifier("m3.confirm.returnToGrouping")
            Button(Copy.Capture.nameRecognitionWrong) {
                showOverrideConfirmation = true
            }
            .buttonStyle(CTSecondaryButtonStyle())
            .accessibilityIdentifier("m3.confirm.nameOverride")
        }
    }

    private var matchingPatient: Patient? {
        guard let evidence = current.evidence,
              M3NameGatePresentationPolicy.canOfferMemberSwitch(
                for: evidence.outcome
              ) else {
            return nil
        }
        return patients.first { patient in
            patient.id != controller.frozenPatientID
                && !Set(patient.normalizedAliases).isDisjoint(
                    with: evidence.reliableNormalizedNames
                )
        }
    }

    private var canSaveDirectly: Bool {
        guard current.sourceType != .manual else { return true }
        return [.match, .noEvidence].contains(current.evidence?.outcome)
    }

    private var confirmationFields: some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Text(Copy.Records.fields)
                    .font(CT.Font.headline)
                ForEach(currentBinding.wrappedValue.structuredFields.indices, id: \.self) { index in
                    HStack(spacing: CT.Space.s2) {
                        TextField(
                            Copy.Common.field,
                            text: Binding(
                                get: { currentBinding.wrappedValue.structuredFields[index].key },
                                set: { currentBinding.wrappedValue.structuredFields[index].key = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                        TextField(
                            Copy.Common.value,
                            text: Binding(
                                get: { currentBinding.wrappedValue.structuredFields[index].value },
                                set: { currentBinding.wrappedValue.structuredFields[index].value = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                    }
                }
            }
        }
    }

    private var abnormalEditor: some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Text(Copy.Capture.abnormalItems)
                    .font(CT.Font.headline)
                ForEach(
                    currentBinding.wrappedValue.abnormalItems.indices,
                    id: \.self
                ) { index in
                    HStack(spacing: CT.Space.s2) {
                        TextField(
                            Copy.Capture.abnormalPlaceholder,
                            text: Binding(
                                get: {
                                    currentBinding.wrappedValue.abnormalItems[index]
                                },
                                set: {
                                    currentBinding.wrappedValue.abnormalItems[index] = $0
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($textInputFocused)
                        .accessibilityIdentifier("m3.confirm.abnormal.\(index)")
                        Button(role: .destructive) {
                            currentBinding.wrappedValue.abnormalItems.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(
                                    width: M3Layout.minimumTouchTarget,
                                    height: M3Layout.minimumTouchTarget
                                )
                        }
                        .accessibilityLabel(Copy.Capture.removeAbnormal)
                    }
                }
                Button {
                    currentBinding.wrappedValue.abnormalItems.append("")
                } label: {
                    Label(Copy.Capture.addAbnormal, systemImage: "plus.circle")
                }
                .buttonStyle(CTSecondaryButtonStyle())
                .accessibilityIdentifier("m3.confirm.addAbnormal")
            }
        }
    }

    private var confirmationMetrics: some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Text(Copy.Capture.metrics)
                    .font(CT.Font.headline)
                ForEach(
                    currentBinding.wrappedValue.labDrafts.indices,
                    id: \.self
                ) { index in
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        HStack(alignment: .top, spacing: CT.Space.s2) {
                            VStack(spacing: CT.Space.s2) {
                                TextField(
                                    Copy.Capture.metricName,
                                    text: labBinding(index, \.name)
                                )
                                .textFieldStyle(.roundedBorder)
                                .focused($textInputFocused)
                                .accessibilityIdentifier("m3.confirm.lab.\(index).name")
                                TextField(
                                    Copy.Capture.metricValue,
                                    text: labBinding(index, \.valueText)
                                )
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .focused($textInputFocused)
                                .accessibilityIdentifier("m3.confirm.lab.\(index).value")
                                TextField(
                                    Copy.Capture.metricUnit,
                                    text: labBinding(index, \.unit)
                                )
                                .textFieldStyle(.roundedBorder)
                                .focused($textInputFocused)
                                .accessibilityIdentifier("m3.confirm.lab.\(index).unit")
                            }
                            VStack(spacing: CT.Space.s2) {
                                TextField(
                                    Copy.Capture.metricReferenceLow,
                                    text: labBinding(index, \.refLowText)
                                )
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .focused($textInputFocused)
                                .accessibilityIdentifier("m3.confirm.lab.\(index).low")
                                TextField(
                                    Copy.Capture.metricReferenceHigh,
                                    text: labBinding(index, \.refHighText)
                                )
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .focused($textInputFocused)
                                .accessibilityIdentifier("m3.confirm.lab.\(index).high")
                                Picker(
                                    Copy.Capture.metricFlag,
                                    selection: labFlagBinding(index)
                                ) {
                                    Text(Copy.Capture.metricNone).tag(LabFlag.none)
                                    Text(Copy.Capture.metricLow).tag(LabFlag.low)
                                    Text(Copy.Capture.metricHigh).tag(LabFlag.high)
                                    Text(Copy.Capture.metricPositive).tag(LabFlag.positive)
                                }
                                .pickerStyle(.menu)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: M3Layout.minimumTouchTarget,
                                    alignment: .leading
                                )
                                .accessibilityIdentifier("m3.confirm.lab.\(index).flag")
                            }
                            Button(role: .destructive) {
                                currentBinding.wrappedValue.labDrafts.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .frame(
                                        width: M3Layout.minimumTouchTarget,
                                        height: M3Layout.minimumTouchTarget
                                    )
                            }
                            .accessibilityLabel(Copy.Capture.removeMetric)
                        }
                        if currentBinding.wrappedValue.labDrafts[index].hasBlankValue {
                            Text(Copy.Capture.metricBlankValue)
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.inkSecondary)
                        } else if currentBinding.wrappedValue.labDrafts[index].hasValidationError {
                            Text(Copy.Capture.metricInvalid)
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.warning)
                                .accessibilityIdentifier("m3.confirm.lab.\(index).error")
                        }
                    }
                }
                Button {
                    currentBinding.wrappedValue.labDrafts.append(M3LabItemDraft())
                } label: {
                    Label(Copy.Capture.addMetric, systemImage: "plus.circle")
                }
                .buttonStyle(CTSecondaryButtonStyle())
                .accessibilityIdentifier("m3.confirm.addMetric")
            }
        }
    }

    private var linkedSuggestions: some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s4) {
                Text(Copy.Capture.linkedSuggestions)
                    .font(CT.Font.headline)
                ForEach(Array(current.machine.medicationHints.enumerated()), id: \.offset) {
                    index,
                    hint in
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        Text(Copy.Capture.medicationSuggestion)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkSecondary)
                        Text(Copy.Capture.medicationSuggestionText(hint))
                            .font(CT.Font.body)
                        Button(Copy.Capture.createMedication) {
                            onMedicationSuggestion(hint)
                        }
                        .buttonStyle(CTSecondaryButtonStyle())
                        .accessibilityIdentifier(
                            "m3.confirm.createMedication.\(index)"
                        )
                    }
                }
                ForEach(Array(current.machine.followUpHints.enumerated()), id: \.offset) {
                    index,
                    hint in
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        Text(Copy.Capture.followUpSuggestion)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkSecondary)
                        Text(Copy.Capture.followUpSuggestionText(hint))
                            .font(CT.Font.body)
                        Button(Copy.Capture.createFollowUp) {
                            onFollowUpSuggestion(hint)
                        }
                        .buttonStyle(CTSecondaryButtonStyle())
                        .accessibilityIdentifier(
                            "m3.confirm.createFollowUp.\(index)"
                        )
                    }
                }
            }
        }
    }

    private func labBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<M3LabItemDraft, String>
    ) -> Binding<String> {
        Binding(
            get: {
                currentBinding.wrappedValue.labDrafts[index][keyPath: keyPath]
            },
            set: {
                currentBinding.wrappedValue.labDrafts[index][keyPath: keyPath] = $0
            }
        )
    }

    private func labFlagBinding(_ index: Int) -> Binding<LabFlag> {
        Binding(
            get: { currentBinding.wrappedValue.labDrafts[index].flag },
            set: { currentBinding.wrappedValue.labDrafts[index].flag = $0 }
        )
    }

    private func adoptAllMachineValues() {
        var value = currentBinding.wrappedValue
        value.type = value.machine.type
        value.title = value.machine.title
        value.summary = value.machine.summary
        value.eventDate = value.machine.eventDate ?? value.eventDate
        value.hospital = value.machine.hospital ?? ""
        value.department = value.machine.department ?? ""
        value.structuredFields = value.machine.structuredFields
        value.labItems = value.machine.labItems
        value.labDrafts = value.machine.labItems.map(M3LabItemDraft.init)
        value.abnormalItems = value.machine.abnormalFlags
        currentBinding.wrappedValue = value
    }

    private func prepareEditableCollections() {
        guard !controller.confirmations.isEmpty else { return }
        var value = currentBinding.wrappedValue
        if value.labDrafts.isEmpty, !value.labItems.isEmpty {
            value.labDrafts = value.labItems.map(M3LabItemDraft.init)
        }
        if value.abnormalItems.isEmpty, !value.machine.abnormalFlags.isEmpty {
            value.abnormalItems = value.machine.abnormalFlags
        }
        currentBinding.wrappedValue = value
    }

    private func saveCurrent(
        decision: AssignmentDecision,
        assignedPatientID: UUID,
        overrideReason: String? = nil
    ) {
        textInputFocused = false
        var finalizedAssets: [FinalizedCaptureAsset] = []
        do {
            let document = current
            let patient = patients.first(where: { $0.id == assignedPatientID })
            let usesFrozenMemberAgeEntry = assignedPatientID == controller.frozenPatientID
                && controller.frozenPatientBirthDate == nil
            let age = AgeCalculator.age(
                birthday: usesFrozenMemberAgeEntry ? nil : patient?.birthDate,
                at: document.eventDate,
                manualAge: usesFrozenMemberAgeEntry || patient?.birthDate == nil
                    ? M3ConfirmationPolicy.manualAge(from: document.manualAgeText)
                    : nil
            ).age
            let reviewStatus = M3ConfirmationPolicy.reviewStatus(
                title: document.title,
                eventDate: document.eventDate
            )
            let recordID = UUID()
            let finalized = try makeAttachments(
                pages: document.pages,
                patientID: assignedPatientID,
                recordID: recordID,
                fallbackSource: document.importSource
            )
            finalizedAssets = finalized.finalized
            let record = MedicalRecord(
                id: recordID,
                patientId: assignedPatientID,
                type: document.type,
                title: document.title,
                summary: document.summary,
                eventDate: document.eventDate,
                hospital: MemberIdentity.optionalTrimmed(document.hospital),
                department: MemberIdentity.optionalTrimmed(document.department),
                doctor: MemberIdentity.optionalTrimmed(document.doctor),
                primaryDisease: document.diseaseValues.first,
                diseaseTags: document.diseaseValues,
                ageAtEvent: age,
                sourceType: document.sourceType,
                ocrText: document.pages.compactMap(\.ocrText).joined(separator: "\n"),
                ocrEngineIdentifier: document.machine.engineIdentifier,
                machineExtractionRevision: document.sourceType == .manual ? 0 : 1,
                confirmedRevision: 1,
                confirmedAt: Date(),
                machineExtraction: document.sourceType == .manual ? nil : document.machine,
                labItems: document.labDrafts.compactMap { $0.materialized() },
                abnormalFlags: document.abnormalItems.compactMap(
                    MemberIdentity.optionalTrimmed
                ),
                structuredFields: document.structuredFields,
                reviewStatus: reviewStatus,
                attachments: finalized.attachments
            )
            if document.sourceType == .manual {
                try RecordRepository(context: modelContext).insert(record)
            } else {
                guard let draftID = document.draftID,
                      let generation = document.generation,
                      let evidence = document.evidence else {
                    throw CaptureCommitError.invalidCaptureDocument
                }
                _ = try CaptureCommitService(context: modelContext).commit(
                    CaptureCommitRequest(
                        draftId: draftID,
                        expectedGeneration: generation,
                        expectedOutcome: evidence.outcome,
                        decision: decision,
                        overrideReason: overrideReason,
                        assignedPatientId: assignedPatientID,
                        record: record,
                        engineIdentifier: document.machine.engineIdentifier,
                        engineVersion: nil
                    )
                )
            }
            if decision == .switchedMember {
                onSwitchMember(assignedPatientID)
            }
            do {
                let vault = try CaptureVaultService()
                try vault.markDatabaseCommitted(finalizedAssets)
                for batchID in Set(document.pages.compactMap(\.batchID)) {
                    try vault.completeBatchIfPossible(batchID)
                }
            } catch {
                // The durable filesMoved transaction remains available for
                // startup reconciliation against the committed database.
                AppLog.vault.error(
                    "Committed capture awaits startup Vault reconciliation"
                )
            }
            let hasRemainingConfirmation = controller.confirmations.count > 1
            if hasRemainingConfirmation {
                controller.confirmations.removeFirst()
            }
            controller.completedRecordCount += 1
            if !hasRemainingConfirmation {
                // Keep the final confirmation snapshot alive until SwiftUI has
                // replaced this form. Its field bindings can be evaluated once
                // more during the phase transition.
                controller.phase = .completed
            }
            onSaved()
        } catch {
            if let vault = try? CaptureVaultService() {
                finalizedAssets.reversed().forEach(vault.rollbackFinalization)
            }
            saveErrorMessage = Copy.Capture.saveFailure
            showSaveError = true
        }
    }

    private func makeAttachments(
        pages: [M3CapturePageAsset],
        patientID: UUID,
        recordID: UUID,
        fallbackSource: ImportSource
    ) throws -> (attachments: [Attachment], finalized: [FinalizedCaptureAsset]) {
        let vault = try CaptureVaultService()
        let batchIDs = Set(pages.compactMap(\.batchID))
        var stagedByID: [UUID: StagedCaptureAsset] = [:]
        var sourceByStagedID: [UUID: ImportSource] = [:]
        for batchID in batchIDs {
            let journal = try vault.journal(batchID: batchID)
            journal.assets.forEach { stagedByID[$0.id] = $0 }
        }
        for page in pages {
            guard let stagedID = page.stagedAssetID else { continue }
            let source = page.captureSource?.importSource ?? fallbackSource
            if let existing = sourceByStagedID[stagedID], existing != source {
                throw CaptureCommitError.invalidCaptureDocument
            }
            sourceByStagedID[stagedID] = source
        }
        var seen = Set<UUID>()
        var attachments: [Attachment] = []
        var finalized: [FinalizedCaptureAsset] = []
        do {
            for page in pages.sorted(by: { $0.sourceOrder < $1.sourceOrder }) {
                guard let stagedID = page.stagedAssetID,
                      seen.insert(stagedID).inserted,
                      let staged = stagedByID[stagedID] else { continue }
                let final = try vault.finalize(
                    asset: staged,
                    patientID: patientID,
                    recordID: recordID
                )
                finalized.append(final)
                attachments.append(
                    try Attachment.verified(
                        id: staged.id,
                        patientId: patientID,
                        recordId: recordID,
                        originalRelativePath: final.finalRelativePath,
                        derivedRelativePath: final.finalPreviewRelativePath,
                        displayFileName: staged.displayName,
                        kind: staged.kind,
                        pageIndex: 0,
                        uniformTypeIdentifier: staged.uniformTypeIdentifier,
                        byteCount: staged.byteCount,
                        sha256: staged.sha256,
                        importedAt: staged.createdAt,
                        importSource: sourceByStagedID[stagedID] ?? fallbackSource,
                        pixelWidth: staged.pixelWidth,
                        pixelHeight: staged.pixelHeight,
                        pageCount: staged.pageCount
                    )
                )
            }
            return (attachments, finalized)
        } catch {
            finalized.reversed().forEach(vault.rollbackFinalization)
            throw error
        }
    }
}

struct M3ConfirmFieldRow<Content: View>: View {
    let title: String
    let machineValue: String
    @ViewBuilder let content: Content

    var body: some View {
        CTCard {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Text(title)
                    .font(CT.Font.headline)
                    .foregroundStyle(CT.Color.inkPrimary)
                if !machineValue.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: CT.Space.s2) {
                        Text(Copy.Capture.machineValue)
                            .font(CT.Font.caption)
                            .foregroundStyle(CT.Color.inkTertiary)
                        Text(machineValue)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkSecondary)
                            .textSelection(.enabled)
                    }
                }
                if !machineValue.isEmpty {
                    Text(Copy.Capture.yourValue)
                        .font(CT.Font.caption)
                        .foregroundStyle(CT.Color.inkTertiary)
                }
                content
            }
        }
    }
}

private extension DateFormatter {
    static let m3Date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = CTDate.calendar
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}
