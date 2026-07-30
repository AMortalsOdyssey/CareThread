import SwiftData
import SwiftUI
import UIKit

struct FollowUpsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    let patientID: UUID
    var notificationCenter: any LocalNotificationCenterAdapting =
        M4M5RuntimeAdapters.localNotificationCenter()
    var calendarStore: any CalendarEventStoreAdapting =
        SystemCalendarEventStore()
    var now: () -> Date = Date.init
    var onCaptureReport: (UUID) -> Void = { _ in }

    @State private var followUps: [FollowUp] = []
    @State private var records: [MedicalRecord] = []
    @State private var showEditor = false
    @State private var editingFollowUp: FollowUp?
    @State private var completingFollowUp: FollowUp?
    @State private var feedback: M4M5SystemFeedback?
    @State private var loadFailed = false

    var body: some View {
        List {
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
                .listRowBackground(Color.clear)
            }
            if loadFailed {
                ContentUnavailableView(
                    Copy.System.dataLoadFailed,
                    systemImage: "exclamationmark.triangle"
                )
                .listRowBackground(Color.clear)
            } else if followUps.isEmpty {
                ContentUnavailableView(
                    Copy.FollowUp.noPlans,
                    systemImage: "calendar.badge.plus"
                )
                .listRowBackground(Color.clear)
            } else {
                section(
                    title: Copy.FollowUp.overdue,
                    ids: sections.overdue,
                    tone: .danger
                )
                section(
                    title: Copy.FollowUp.nextThirtyDays,
                    ids: sections.nextThirtyDays,
                    tone: .primary
                )
                section(
                    title: Copy.FollowUp.later,
                    ids: sections.later,
                    tone: .standard
                )
                section(
                    title: Copy.FollowUp.completed,
                    ids: sections.completed,
                    tone: .standard
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.FollowUp.navigationTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Copy.FollowUp.add)
                .accessibilityIdentifier("m45.followup.add")
            }
        }
        .sheet(isPresented: $showEditor) {
            FollowUpEditorView(
                patientID: patientID,
                records: records,
                notificationCenter: notificationCenter
            ) { value in
                feedback = value
                reload()
            }
        }
        .sheet(item: $editingFollowUp) { followUp in
            FollowUpEditorView(
                patientID: patientID,
                followUp: followUp,
                records: records,
                notificationCenter: notificationCenter
            ) { value in
                feedback = value
                reload()
            }
        }
        .confirmationDialog(
            Copy.FollowUp.completionQuestion,
            isPresented: Binding(
                get: { completingFollowUp != nil },
                set: { if !$0 { completingFollowUp = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(Copy.FollowUp.captureReport) {
                if let followUp = completingFollowUp {
                    complete(followUp, thenCapture: true)
                }
            }
            Button(Copy.FollowUp.completeOnly) {
                if let followUp = completingFollowUp {
                    complete(followUp, thenCapture: false)
                }
            }
            Button(Copy.Medication.cancel, role: .cancel) {
                completingFollowUp = nil
            }
        }
        .task(id: patientID) {
            reload()
        }
        .refreshable {
            reload()
        }
        .accessibilityIdentifier("m45.followup.list")
    }

    private var sections: FollowUpSections {
        FollowUpSections.make(followUps: followUps, now: now())
    }

    @ViewBuilder
    private func section(
        title: String,
        ids: [UUID],
        tone: M4M5CardTone
    ) -> some View {
        if !ids.isEmpty {
            Section(title) {
                ForEach(ids, id: \.self) { id in
                    if let followUp = followUps.first(where: { $0.id == id }) {
                        FollowUpCardView(
                            followUp: followUp,
                            availableRecords: records,
                            now: now(),
                            tone: tone,
                            onEdit: { editingFollowUp = followUp },
                            onComplete: {
                                completingFollowUp = followUp
                            },
                            onCalendar: {
                                addToCalendar(followUp)
                            }
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func reload() {
        do {
            let repository = FollowUpRepository(
                context: modelContext,
                now: now
            )
            followUps = try repository.fetch(patientID: patientID)
            records = try repository.fetchRecords(patientID: patientID)
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.data.error("Follow-up list load failed")
        }
    }

    @MainActor
    private func complete(
        _ followUp: FollowUp,
        thenCapture: Bool
    ) {
        do {
            try FollowUpRepository(
                context: modelContext,
                now: now
            ).completeOnly(followUp)
            Task {
                await AppleReminderScheduler(
                    center: notificationCenter
                ).removeManagedRequests(reminderID: followUp.id)
            }
            completingFollowUp = nil
            reload()
            if thenCapture {
                onCaptureReport(followUp.id)
            }
        } catch {
            feedback = .failed
        }
    }

    @MainActor
    private func addToCalendar(_ followUp: FollowUp) {
        let memberName = (
            try? modelContext.fetch(
                FetchDescriptor<Patient>(
                    predicate: #Predicate { $0.id == patientID }
                )
            ).first?.displayName
        ) ?? ""
        Task { @MainActor in
            do {
                let result = try await CalendarExportService(
                    store: calendarStore
                ).addFollowUpUserInitiated(
                    followUp,
                    memberName: memberName
                )
                switch result {
                case let .added(identifier):
                    try FollowUpRepository(
                        context: modelContext,
                        now: now
                    ).bindCalendarEvent(
                        followUp: followUp,
                        eventIdentifier: identifier
                    )
                    feedback = .calendarAdded
                case .permissionDenied:
                    feedback = .calendarDenied
                }
            } catch {
                feedback = .calendarFailed
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
    }
}

private struct FollowUpCardView: View {
    let followUp: FollowUp
    let availableRecords: [MedicalRecord]
    let now: Date
    let tone: M4M5CardTone
    let onEdit: () -> Void
    let onComplete: () -> Void
    let onCalendar: () -> Void

    var body: some View {
        M4M5Card(tone: tone) {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                HStack(alignment: .top, spacing: CT.Space.s3) {
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Text(followUp.items.joined(separator: "、"))
                            .font(CT.Font.headline)
                            .foregroundStyle(CT.Color.inkPrimary)
                        Text(M4M5DateFormatting.fullDay.string(from: followUp.plannedDate))
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkSecondary)
                    }
                    Spacer()
                    if followUp.status == .pending {
                        Text(countdown)
                            .font(CT.Font.caption)
                            .foregroundStyle(
                                M4M5CalendarMath.dayDistance(
                                    from: now,
                                    to: followUp.plannedDate
                                ) < 0 ? CT.Color.danger : CT.Color.primary
                            )
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(CT.Color.success)
                    }
                }
                if let reason = followUp.reason {
                    Text(reason)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                }
                let references = FollowUpRecordReferenceResolver.resolve(
                    ids: followUp.bringRecordIds,
                    availableRecords: availableRecords
                )
                if !references.isEmpty {
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Text(Copy.FollowUp.bringRecords)
                            .font(CT.Font.caption)
                            .foregroundStyle(CT.Color.inkSecondary)
                        ForEach(references) { reference in
                            Label(
                                reference.displayTitle,
                                systemImage: reference.isDeleted
                                    ? "doc.badge.ellipsis"
                                    : "doc.text"
                            )
                            .font(CT.Font.footnote)
                            .foregroundStyle(
                                reference.isDeleted
                                    ? CT.Color.danger
                                    : CT.Color.inkSecondary
                            )
                            .accessibilityIdentifier(
                                reference.isDeleted
                                    ? "m45.followup.deleted-record"
                                    : "m45.followup.record.\(reference.id.uuidString)"
                            )
                        }
                    }
                }
                HStack(spacing: CT.Space.s2) {
                    Button(Copy.FollowUp.edit, action: onEdit)
                        .buttonStyle(.bordered)
                    if followUp.status == .pending {
                        Button(Copy.FollowUp.markCompleted, action: onComplete)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(
                                "m45.followup.complete.\(followUp.id.uuidString)"
                            )
                        Button(action: onCalendar) {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(Copy.FollowUp.calendar)
                        .accessibilityIdentifier(
                            "m45.followup.calendar.\(followUp.id.uuidString)"
                        )
                    }
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
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
    }

    private var countdown: String {
        let days = M4M5CalendarMath.dayDistance(
            from: now,
            to: followUp.plannedDate
        )
        return days < 0
            ? String(format: Copy.FollowUp.overdueDaysFormat, abs(days))
            : String(format: Copy.FollowUp.daysRemainingFormat, days)
    }
}

private struct FollowUpEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let patientID: UUID
    let followUp: FollowUp?
    let records: [MedicalRecord]
    let notificationCenter: any LocalNotificationCenterAdapting
    let onSaved: (M4M5SystemFeedback?) -> Void

    @State private var state: FollowUpFormState
    @State private var failed = false
    private let now: () -> Date

    init(
        patientID: UUID,
        followUp: FollowUp? = nil,
        records: [MedicalRecord],
        notificationCenter: any LocalNotificationCenterAdapting,
        now: @escaping () -> Date = Date.init,
        onSaved: @escaping (M4M5SystemFeedback?) -> Void
    ) {
        self.patientID = patientID
        self.followUp = followUp
        self.records = records
        self.notificationCenter = notificationCenter
        self.now = now
        self.onSaved = onSaved
        _state = State(
            initialValue: followUp.map(FollowUpFormState.init) ??
                FollowUpFormState(now: now())
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    Copy.FollowUp.date,
                    selection: $state.plannedDate,
                    displayedComponents: .date
                )
                TextField(
                    Copy.FollowUp.items,
                    text: $state.itemsText,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .accessibilityIdentifier("m45.followup.items")
                TextField(
                    Copy.FollowUp.reason,
                    text: $state.reason,
                    axis: .vertical
                )
                let deletedReferences = FollowUpRecordReferenceResolver.resolve(
                    ids: Array(state.bringRecordIDs).sorted {
                        $0.uuidString < $1.uuidString
                    },
                    availableRecords: records
                ).filter(\.isDeleted)
                if !records.isEmpty || !deletedReferences.isEmpty {
                    Section(Copy.FollowUp.bringRecords) {
                        ForEach(deletedReferences) { reference in
                            Toggle(
                                reference.displayTitle,
                                isOn: recordSelection(reference.id)
                            )
                            .foregroundStyle(CT.Color.danger)
                            .accessibilityIdentifier(
                                "m45.followup.deleted-record-toggle"
                            )
                        }
                        ForEach(records) { record in
                            Toggle(
                                "\(record.displayTitle) · \(M4M5DateFormatting.day.string(from: record.eventDate))",
                                isOn: recordSelection(record.id)
                            )
                        }
                    }
                    Section(Copy.FollowUp.compareTarget) {
                        Picker(
                            Copy.FollowUp.compareTarget,
                            selection: $state.compareRecordID
                        ) {
                            Text(Copy.FollowUp.noCompareTarget).tag(UUID?.none)
                            ForEach(records) { record in
                                Text(record.displayTitle).tag(Optional(record.id))
                            }
                        }
                    }
                }
                Toggle(Copy.FollowUp.reminder, isOn: $state.reminderEnabled)
                    .accessibilityIdentifier("m45.followup.reminder")
                if let message = state.validation(now: now()).message {
                    Text(message)
                        .foregroundStyle(CT.Color.danger)
                        .accessibilityIdentifier("m45.followup.validation")
                }
                if failed {
                    Text(Copy.System.schedulingFailed)
                        .foregroundStyle(CT.Color.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CT.Color.bgBase)
            .navigationTitle(
                followUp == nil ? Copy.FollowUp.add : Copy.FollowUp.edit
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Medication.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.FollowUp.save) { save() }
                        .disabled(state.validation(now: now()) != .valid)
                        .accessibilityIdentifier("m45.followup.save")
                }
            }
        }
        .accessibilityIdentifier("m45.followup.editor")
    }

    private func recordSelection(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { state.bringRecordIDs.contains(id) },
            set: {
                if $0 {
                    state.bringRecordIDs.insert(id)
                } else {
                    state.bringRecordIDs.remove(id)
                }
            }
        )
    }

    @MainActor
    private func save() {
        do {
            let saved: FollowUp
            if let followUp,
               let content = state.editableContent(
                    from: followUp,
                    now: now()
               ) {
                _ = try MedicalOrderService(
                    context: modelContext,
                    now: now
                ).editFollowUp(
                    followUpId: followUp.id,
                    patientId: patientID,
                    content: content,
                    changedFieldKeys: [
                        "plannedDate", "items", "reason", "bringRecordIds",
                        "compareRecordId", "reminderEnabled"
                    ],
                    expectedRevision: followUp.contentRevision
                )
                saved = followUp
            } else {
                saved = try FollowUpRepository(
                    context: modelContext,
                    now: now
                ).create(patientID: patientID, state: state)
            }
            Task { @MainActor in
                let feedback: M4M5SystemFeedback?
                if saved.reminderEnabled {
                    do {
                        let result = try await AppleReminderScheduler(
                            center: notificationCenter,
                            now: now
                        ).scheduleFollowUpUserInitiated(followUp: saved)
                        switch result {
                        case .permissionDenied:
                            feedback = .followUpNotificationDenied
                        case .scheduled:
                            feedback = .notificationScheduled
                        case .disabled, .noFutureOccurrence:
                            feedback = nil
                        }
                    } catch {
                        feedback = .failed
                    }
                } else {
                    await AppleReminderScheduler(
                        center: notificationCenter,
                        now: now
                    ).removeManagedRequests(reminderID: saved.id)
                    feedback = nil
                }
                onSaved(feedback)
                dismiss()
            }
        } catch {
            failed = true
            AppLog.data.error("Follow-up form save failed")
        }
    }
}
