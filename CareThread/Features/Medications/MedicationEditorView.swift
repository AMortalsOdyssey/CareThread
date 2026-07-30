import SwiftData
import SwiftUI
import UIKit

enum M4M5SystemFeedback: Equatable {
    case notificationScheduled
    case notificationDenied
    case followUpNotificationDenied
    case calendarAdded
    case calendarDenied
    case calendarFailed
    case failed

    var message: String {
        switch self {
        case .notificationScheduled: Copy.Medication.notificationScheduled
        case .notificationDenied: Copy.Medication.reminderPermissionDenied
        case .followUpNotificationDenied:
            Copy.FollowUp.notificationPermissionDenied
        case .calendarAdded: Copy.FollowUp.calendarAdded
        case .calendarDenied: Copy.FollowUp.calendarPermissionDenied
        case .calendarFailed: Copy.System.calendarFailed
        case .failed: Copy.System.schedulingFailed
        }
    }

    var requiresSettings: Bool {
        self == .notificationDenied ||
            self == .followUpNotificationDenied ||
            self == .calendarDenied
    }

    var isDanger: Bool {
        self == .failed || self == .calendarFailed
    }
}

struct MedicationEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let patientID: UUID
    let medication: Medication?
    let notificationCenter: any LocalNotificationCenterAdapting
    let onSaved: (Medication, M4M5SystemFeedback?) -> Void

    @State private var state: MedicationFormState
    @State private var feedback: M4M5SystemFeedback?
    @State private var isSaving = false

    init(
        patientID: UUID,
        medication: Medication? = nil,
        notificationCenter: any LocalNotificationCenterAdapting =
            M4M5RuntimeAdapters.localNotificationCenter(),
        now: Date = Date(),
        onSaved: @escaping (Medication, M4M5SystemFeedback?) -> Void
    ) {
        self.patientID = patientID
        self.medication = medication
        self.notificationCenter = notificationCenter
        self.onSaved = onSaved
        _state = State(
            initialValue: medication.map {
                MedicationFormState(medication: $0, now: now)
            } ?? MedicationFormState(now: now)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                medicationSection
                scheduleSection
                sourceSection
                refillSection
                reminderSection
                if let message = state.validation.message {
                    Text(message)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.danger)
                        .accessibilityIdentifier("m45.medication.validation")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CT.Color.bgBase)
            .navigationTitle(
                medication == nil ? Copy.Medication.add : Copy.Medication.edit
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Medication.cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Medication.save) {
                        save()
                    }
                    .disabled(!state.canSave || isSaving)
                    .accessibilityIdentifier("m45.medication.save")
                }
            }
            .safeAreaInset(edge: .top) {
                if let feedback {
                    M4M5StatusBanner(
                        message: feedback.message,
                        isDanger: feedback.isDanger,
                        actionTitle: feedback.requiresSettings
                            ? Copy.Medication.openSettings
                            : nil,
                        action: feedback.requiresSettings
                            ? openSystemSettings
                            : nil
                    )
                    .padding(.horizontal, CT.Space.s4)
                    .padding(.top, CT.Space.s2)
                    .background(CT.Color.bgBase)
                    .accessibilityIdentifier("m45.medication.feedback")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .accessibilityIdentifier("m45.medication.editor")
    }

    private var medicationSection: some View {
        Section {
            TextField(Copy.Medication.name, text: $state.name)
                .textContentType(.name)
                .accessibilityIdentifier("m45.medication.name")
            HStack {
                TextField(Copy.Medication.dose, text: $state.doseText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("m45.medication.dose")
                Picker(Copy.Medication.doseUnit, selection: $state.doseUnit) {
                    ForEach(Copy.Medication.units, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("m45.medication.unit")
            }
            Picker(Copy.Medication.frequency, selection: frequencyBinding) {
                ForEach(FrequencyPreset.allCases, id: \.self) {
                    Text($0.m4m5DisplayName).tag($0)
                }
            }
            .accessibilityIdentifier("m45.medication.frequency")
            if state.frequency == .weekly {
                Stepper(
                    "\(Copy.Medication.weeklyCount)：\(state.weeklyCount)",
                    value: $state.weeklyCount,
                    in: 1...7
                )
            }
        }
    }

    private var scheduleSection: some View {
        Section(Copy.Medication.usage) {
            M4M5ChipGrid(
                values: Copy.Medication.usageOptions,
                selected: $state.usageNotes
            )
            DatePicker(
                Copy.Medication.startDate,
                selection: $state.startDate,
                displayedComponents: .date
            )
            Toggle(Copy.Medication.longTerm, isOn: $state.isLongTerm)
            if !state.isLongTerm {
                DatePicker(
                    Copy.Medication.endDate,
                    selection: $state.endDate,
                    displayedComponents: .date
                )
            }
        }
    }

    private var sourceSection: some View {
        Section {
            TextField(Copy.Medication.hospital, text: $state.hospital)
            TextField(Copy.Medication.department, text: $state.department)
            TextField(Copy.Medication.diagnosis, text: $state.linkedDiagnosis)
            TextField(Copy.Medication.caution, text: $state.caution, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var refillSection: some View {
        Section {
            TextField(
                Copy.Medication.remaining,
                text: $state.remainingQuantityText
            )
            .keyboardType(.decimalPad)
            Toggle(
                Copy.Medication.refillDate,
                isOn: $state.refillReminderEnabled
            )
            if state.refillReminderEnabled {
                DatePicker(
                    Copy.Medication.refillDate,
                    selection: $state.refillReminderAt
                )
            }
        }
    }

    private var reminderSection: some View {
        Section {
            HStack {
                Text(Copy.Medication.reminder)
                Spacer()
                Toggle("", isOn: reminderEnabledBinding)
                    .labelsHidden()
                    .disabled(state.frequency == .asNeeded)
                    .accessibilityLabel(Copy.Medication.reminder)
                    .accessibilityIdentifier("m45.medication.reminder")
            }
            if state.frequency == .asNeeded {
                Text(Copy.Medication.asNeededNoReminder)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
            if state.reminderEnabled {
                ForEach(state.reminderTimes.indices, id: \.self) { index in
                    M4M5ReminderTimePicker(
                        title: "\(Copy.Medication.reminderTimes) \(index + 1)",
                        time: reminderTimeBinding(at: index)
                    )
                }
            }
        }
    }

    private var frequencyBinding: Binding<FrequencyPreset> {
        Binding(
            get: { state.frequency },
            set: { state.changeFrequency(to: $0) }
        )
    }

    private var reminderEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.reminderEnabled },
            set: { state.setReminderEnabled($0) }
        )
    }

    private func reminderTimeBinding(at index: Int) -> Binding<ReminderTime> {
        Binding(
            get: { state.reminderTimes[index] },
            set: { state.reminderTimes[index] = $0 }
        )
    }

    @MainActor
    private func save() {
        guard state.canSave else { return }
        isSaving = true
        do {
            let service = MedicationService(context: modelContext)
            let saved: Medication
            if let medication,
               let content = state.editableContent(
                    from: medication,
                    updatedAt: Date()
               ) {
                _ = try service.edit(
                    medicationId: medication.id,
                    patientId: patientID,
                    content: content,
                    changedFieldKeys: [
                        "name", "doseValue", "doseUnit", "frequency",
                        "weeklyCount", "usageNotes", "startDate", "endDate",
                        "isLongTerm", "hospital", "department",
                        "linkedDiagnosis", "caution", "reminderEnabled",
                        "reminderTimes", "remainingQuantity", "refillReminderAt"
                    ],
                    expectedRevision: medication.contentRevision
                )
                saved = medication
            } else if let draft = state.draft(patientID: patientID) {
                saved = try service.create(draft)
            } else {
                isSaving = false
                return
            }
            AppLog.data.info("Saved medication from user form")
            Task { @MainActor in
                let systemFeedback = await scheduleIfNeeded(saved)
                isSaving = false
                onSaved(saved, systemFeedback)
                // The medication is already durably saved at this point.
                // Return to the list for every scheduling outcome so the
                // parent can present a persistent, actionable recovery
                // banner instead of leaving a completed form on screen.
                dismiss()
            }
        } catch {
            isSaving = false
            feedback = .failed
            AppLog.data.error("Medication form save failed")
        }
    }

    @MainActor
    private func scheduleIfNeeded(
        _ medication: Medication
    ) async -> M4M5SystemFeedback? {
        guard medication.reminderEnabled else {
            await AppleReminderScheduler(
                center: notificationCenter
            ).removeManagedRequests(reminderID: medication.id)
            return nil
        }
        do {
            let result = try await AppleReminderScheduler(
                center: notificationCenter
            ).scheduleMedicationUserInitiated(medication: medication)
            switch result {
            case .permissionDenied:
                return .notificationDenied
            case .scheduled:
                return .notificationScheduled
            case .disabled, .noFutureOccurrence:
                return nil
            }
        } catch {
            AppLog.data.error("Medication saved but local reminder scheduling failed")
            return .failed
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
    }
}

private struct M4M5ChipGrid: View {
    let values: [String]
    @Binding var selected: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CT.Space.s2) {
                ForEach(values, id: \.self) { value in
                    Button {
                        if selected.contains(value) {
                            selected.remove(value)
                        } else {
                            selected.insert(value)
                        }
                    } label: {
                        Text(value)
                            .font(CT.Font.footnote)
                            .foregroundStyle(
                                selected.contains(value)
                                    ? CT.Color.inkOnPrimary
                                    : CT.Color.primary
                            )
                            .padding(.horizontal, CT.Space.s3)
                            .frame(minHeight: CT.Size.secondaryButtonHeight)
                            .background(
                                selected.contains(value)
                                    ? CT.Color.primary
                                    : CT.Color.primaryContainer
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct M4M5ReminderTimePicker: View {
    let title: String
    @Binding var time: ReminderTime

    var body: some View {
        DatePicker(
            title,
            selection: dateBinding,
            displayedComponents: .hourAndMinute
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: time.hour,
                    minute: time.minute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: {
                let components = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: $0
                )
                time = ReminderTime(
                    hour: components.hour ?? 8,
                    minute: components.minute ?? 0
                )
            }
        )
    }
}
