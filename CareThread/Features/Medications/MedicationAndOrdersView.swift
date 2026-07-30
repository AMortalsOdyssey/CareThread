import SwiftData
import SwiftUI

enum MedicationOrderSegment: String, CaseIterable {
    case medications
    case orders

    var title: String {
        switch self {
        case .medications: Copy.Medication.medicationSegment
        case .orders: Copy.Medication.orderSegment
        }
    }
}

struct MedicationAndOrdersView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    let patientID: UUID
    var notificationCenter: any LocalNotificationCenterAdapting =
        M4M5RuntimeAdapters.localNotificationCenter()
    var onFollowUpCreated: (UUID) -> Void = { _ in }

    @State private var segment = MedicationOrderSegment.medications
    @State private var medications: [Medication] = []
    @State private var orders: [MedicalOrder] = []
    @State private var showMedicationEditor = false
    @State private var showOrderEditor = false
    @State private var editingOrder: MedicalOrder?
    @State private var followUpOrder: MedicalOrder?
    @State private var feedback: M4M5SystemFeedback?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: CT.Space.s4) {
            Picker(Copy.Medication.navigationTitle, selection: $segment) {
                ForEach(MedicationOrderSegment.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, CT.Space.s4)
            .accessibilityIdentifier("m45.medication.segment")

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
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("m45.medication.feedback")
            }

            if loadFailed {
                ContentUnavailableView(
                    Copy.System.dataLoadFailed,
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                switch segment {
                case .medications:
                    medicationList
                case .orders:
                    orderList
                }
            }
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Medication.navigationTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if segment == .medications {
                        showMedicationEditor = true
                    } else {
                        showOrderEditor = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(
                    segment == .medications
                        ? Copy.Medication.add
                        : Copy.Medication.addOrder
                )
                .accessibilityIdentifier("m45.medication.add")
            }
        }
        .sheet(isPresented: $showMedicationEditor) {
            MedicationEditorView(
                patientID: patientID,
                notificationCenter: notificationCenter
            ) { _, value in
                feedback = value
                reload()
            }
        }
        .sheet(isPresented: $showOrderEditor) {
            MedicalOrderEditorView(patientID: patientID) {
                reload()
            }
        }
        .sheet(item: $editingOrder) { order in
            MedicalOrderEditorView(
                patientID: patientID,
                order: order
            ) {
                reload()
            }
        }
        .sheet(item: $followUpOrder) { order in
            OrderFollowUpEditorView(
                patientID: patientID,
                order: order,
                notificationCenter: notificationCenter
            ) { followUp, value in
                feedback = value
                onFollowUpCreated(followUp.id)
                reload()
            }
        }
        .task(id: patientID) {
            reload()
        }
        .refreshable {
            reload()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("m45.medication.orders")
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
    }

    private var activeMedications: [Medication] {
        medications.filter { $0.lifecycleStatus == .active }
    }

    private var inactiveMedications: [Medication] {
        medications.filter { $0.lifecycleStatus != .active }
    }

    private var medicationList: some View {
        List {
            if activeMedications.isEmpty {
                ContentUnavailableView(
                    Copy.Medication.noActive,
                    systemImage: "pills"
                )
                .listRowBackground(Color.clear)
            } else {
                Section(Copy.Medication.active) {
                    ForEach(activeMedications) { medication in
                        NavigationLink {
                            MedicationDetailView(
                                medication: medication,
                                notificationCenter: notificationCenter
                            ) {
                                reload()
                            }
                        } label: {
                            MedicationCardView(medication: medication)
                        }
                    }
                }
            }
            if !inactiveMedications.isEmpty {
                Section(Copy.Medication.inactive) {
                    ForEach(inactiveMedications) {
                        MedicationCardView(medication: $0)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("m45.medication.list")
    }

    private var orderList: some View {
        List {
            if orders.isEmpty {
                ContentUnavailableView(
                    Copy.Medication.noOrders,
                    systemImage: "doc.text"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(orders) { order in
                    VStack(alignment: .leading, spacing: CT.Space.s3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(order.content)
                                .font(CT.Font.body)
                                .foregroundStyle(CT.Color.inkPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                editingOrder = order
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("编辑医嘱")
                            .accessibilityIdentifier(
                                "m45.order.edit.\(order.id.uuidString)"
                            )
                        }
                        if order.isCompleted {
                            Label(
                                Copy.Medication.done,
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(CT.Font.footnote)
                            .foregroundStyle(CT.Color.success)
                        }
                        HStack(spacing: CT.Space.s3) {
                            if order.generatedFollowUpId == nil {
                                Button(Copy.Medication.generateFollowUp) {
                                    followUpOrder = order
                                }
                                .font(CT.Font.subhead.weight(.semibold))
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier(
                                    "m45.order.generate.\(order.id.uuidString)"
                                )
                            } else {
                                Label(
                                    Copy.Medication.generatedFollowUp,
                                    systemImage: "calendar.badge.checkmark"
                                )
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.success)
                            }
                        }
                    }
                    .padding(.vertical, CT.Space.s2)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("m45.order.list")
    }

    @MainActor
    private func reload() {
        do {
            var medicationDescriptor = FetchDescriptor<Medication>(
                predicate: #Predicate { $0.patientId == patientID },
                sortBy: [
                    SortDescriptor(\.startDate, order: .reverse),
                    SortDescriptor(\.createdAt, order: .reverse)
                ]
            )
            medicationDescriptor.fetchLimit = M4M5QueryLimit.standard
            medications = try modelContext.fetch(medicationDescriptor)

            var orderDescriptor = FetchDescriptor<MedicalOrder>(
                predicate: #Predicate { $0.patientId == patientID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            orderDescriptor.fetchLimit = M4M5QueryLimit.standard
            orders = try modelContext.fetch(orderDescriptor)
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.data.error("Medication and medical order list load failed")
        }
    }
}

private struct MedicationCardView: View {
    let medication: Medication

    var body: some View {
        HStack(spacing: CT.Space.s3) {
            Image(systemName: "pills.fill")
                .foregroundStyle(CT.Color.primary)
                .frame(width: CT.Size.leadingIcon, height: CT.Size.leadingIcon)
                .background(CT.Color.primaryContainer)
                .clipShape(RoundedRectangle(cornerRadius: CT.Radius.input))
            VStack(alignment: .leading, spacing: CT.Space.s1) {
                Text(medication.name)
                    .font(CT.Font.headline)
                    .foregroundStyle(CT.Color.inkPrimary)
                Text(
                    [
                        medication.doseValue.map {
                            $0.formatted(.number.precision(.fractionLength(0...2)))
                        }.map { $0 + medication.doseUnit },
                        medication.frequency.m4m5DisplayName,
                        medication.reminderTimes.isEmpty
                            ? nil
                            : medication.reminderTimes
                                .map(M4M5DateFormatting.clock)
                                .joined(separator: " · ")
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                )
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
                if let remaining = medication.remainingQuantity {
                    Text(
                        "\(Copy.Medication.remaining)：\(remaining.formatted(.number.precision(.fractionLength(0...2))))"
                    )
                    .font(CT.Font.caption)
                    .foregroundStyle(CT.Color.inkTertiary)
                }
            }
        }
        .frame(minHeight: CT.Size.listRowHeight)
        .accessibilityIdentifier(
            "m45.medication.row.\(medication.id.uuidString)"
        )
    }
}

private struct MedicationDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let medication: Medication
    let notificationCenter: any LocalNotificationCenterAdapting
    let onChanged: () -> Void

    @State private var showEditor = false
    @State private var showAdjustment = false
    @State private var feedback: M4M5SystemFeedback?

    var body: some View {
        List {
            if let feedback {
                M4M5StatusBanner(message: feedback.message)
                    .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent(Copy.Medication.name, value: medication.name)
                LabeledContent(
                    Copy.Medication.dose,
                    value: [
                        medication.doseValue.map {
                            $0.formatted(.number.precision(.fractionLength(0...2)))
                        },
                        medication.doseUnit
                    ].compactMap { $0 }.joined()
                )
                LabeledContent(
                    Copy.Medication.frequency,
                    value: medication.frequency.m4m5DisplayName
                )
                LabeledContent(
                    Copy.Medication.startDate,
                    value: M4M5DateFormatting.fullDay.string(
                        from: medication.startDate
                    )
                )
            }
            if medication.lifecycleStatus == .active {
                Section {
                    Button(Copy.Medication.adjustDose) {
                        showAdjustment = true
                    }
                    Button(Copy.Medication.edit) {
                        showEditor = true
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Medication.detail)
        .sheet(isPresented: $showEditor) {
            MedicationEditorView(
                patientID: medication.patientId,
                medication: medication,
                notificationCenter: notificationCenter
            ) { _, value in
                feedback = value
                onChanged()
            }
        }
        .sheet(isPresented: $showAdjustment) {
            MedicationDoseAdjustmentView(medication: medication) {
                onChanged()
            }
        }
    }
}

private struct MedicationDoseAdjustmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let medication: Medication
    let onSaved: () -> Void

    @State private var doseText = ""
    @State private var unit: String
    @State private var effectiveDate = Date()
    @State private var errorMessage: String?

    init(medication: Medication, onSaved: @escaping () -> Void) {
        self.medication = medication
        self.onSaved = onSaved
        _unit = State(initialValue: medication.doseUnit)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(Copy.Medication.dose, text: $doseText)
                    .keyboardType(.decimalPad)
                Picker(Copy.Medication.doseUnit, selection: $unit) {
                    ForEach(Copy.Medication.units, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                DatePicker(
                    Copy.Medication.startDate,
                    selection: $effectiveDate,
                    displayedComponents: .date
                )
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(CT.Color.danger)
                }
            }
            .navigationTitle(Copy.Medication.adjustDose)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Medication.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Medication.save) { save() }
                }
            }
        }
    }

    @MainActor
    private func save() {
        guard let dose = Double(doseText), dose > 0 else {
            errorMessage = Copy.Medication.invalidDose
            return
        }
        do {
            _ = try MedicationService(context: modelContext).adjustDose(
                medicationId: medication.id,
                patientId: medication.patientId,
                expectedRevision: medication.contentRevision,
                doseValue: dose,
                doseUnit: unit,
                effectiveAt: effectiveDate
            )
            AppLog.data.info("Adjusted medication dose from detail")
            onSaved()
            dismiss()
        } catch {
            errorMessage = Copy.Medication.endBeforeStart
            AppLog.data.error("Medication dose adjustment failed")
        }
    }
}

private struct MedicalOrderEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let patientID: UUID
    let order: MedicalOrder?
    let onSaved: () -> Void
    @State private var content: String
    @State private var isCompleted: Bool
    @State private var baseRevision: Int?
    @State private var failed = false
    @State private var errorMessage = Copy.System.schedulingFailed

    init(
        patientID: UUID,
        order: MedicalOrder? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.patientID = patientID
        self.order = order
        self.onSaved = onSaved
        _content = State(initialValue: order?.content ?? "")
        _isCompleted = State(initialValue: order?.isCompleted ?? false)
        _baseRevision = State(initialValue: order?.contentRevision)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    Copy.Medication.orderContent,
                    text: $content,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .accessibilityIdentifier("m45.order.content")
                Toggle(
                    "医嘱已完成",
                    isOn: $isCompleted
                )
                .tint(CT.Color.primary)
                .accessibilityIdentifier("m45.order.completed")
                if failed {
                    Text(errorMessage)
                        .foregroundStyle(CT.Color.danger)
                }
            }
            .navigationTitle(
                order == nil ? Copy.Medication.addOrder : "编辑医嘱"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Medication.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Medication.saveOrder) { save() }
                        .disabled(
                            content.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                        .accessibilityIdentifier("m45.order.save")
                }
            }
        }
    }

    @MainActor
    private func save() {
        do {
            let service = MedicalOrderService(context: modelContext)
            if let order, let baseRevision {
                var editable = order.editableContent()
                editable.content = content
                editable.isCompleted = isCompleted
                _ = try service.editOrder(
                    orderId: order.id,
                    patientId: patientID,
                    content: editable,
                    changedFieldKeys: ["content", "isCompleted"],
                    expectedRevision: baseRevision
                )
            } else {
                let value = try service.createOrder(
                    patientId: patientID,
                    content: content
                )
                if isCompleted {
                    var editable = value.editableContent()
                    editable.isCompleted = true
                    _ = try service.editOrder(
                        orderId: value.id,
                        patientId: patientID,
                        content: editable,
                        changedFieldKeys: ["isCompleted"],
                        expectedRevision: value.contentRevision
                    )
                }
            }
            AppLog.data.info("Saved medical order from user form")
            onSaved()
            dismiss()
        } catch MedicalOrderServiceError.noChanges {
            dismiss()
        } catch MedicalOrderServiceError.revisionConflict {
            failed = true
            errorMessage = Copy.Records.revisionConflict
            AppLog.data.warning("Rejected stale medical order form")
        } catch {
            failed = true
            errorMessage = Copy.System.schedulingFailed
            AppLog.data.error("Medical order form save failed")
        }
    }
}

private struct OrderFollowUpEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let patientID: UUID
    let order: MedicalOrder
    let notificationCenter: any LocalNotificationCenterAdapting
    let onSaved: (FollowUp, M4M5SystemFeedback?) -> Void

    @State private var date: Date
    @State private var item: String
    @State private var reason: String
    @State private var reminderEnabled = true
    @State private var failed = false

    init(
        patientID: UUID,
        order: MedicalOrder,
        notificationCenter: any LocalNotificationCenterAdapting,
        now: Date = Date(),
        onSaved: @escaping (FollowUp, M4M5SystemFeedback?) -> Void
    ) {
        let prefill = OrderFollowUpPrefill.make(
            orderText: order.content,
            now: now
        )
        self.patientID = patientID
        self.order = order
        self.notificationCenter = notificationCenter
        self.onSaved = onSaved
        _date = State(initialValue: prefill.plannedDate)
        _item = State(initialValue: prefill.item)
        _reason = State(initialValue: prefill.reason)
    }

    var body: some View {
        NavigationStack {
            Form {
                M4M5StatusBanner(message: Copy.FollowUp.fromOrder)
                    .listRowBackground(Color.clear)
                DatePicker(
                    Copy.FollowUp.date,
                    selection: $date,
                    displayedComponents: .date
                )
                TextField(Copy.FollowUp.items, text: $item)
                    .accessibilityIdentifier("m45.order.followup.item")
                TextField(Copy.FollowUp.reason, text: $reason, axis: .vertical)
                Toggle(Copy.FollowUp.reminder, isOn: $reminderEnabled)
                if failed {
                    Text(Copy.System.schedulingFailed)
                        .foregroundStyle(CT.Color.danger)
                }
            }
            .navigationTitle(Copy.Medication.generateFollowUp)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Medication.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.FollowUp.save) { save() }
                        .disabled(
                            item.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                        .accessibilityIdentifier("m45.order.followup.save")
                }
            }
        }
        .accessibilityIdentifier("m45.order.followup.editor")
    }

    @MainActor
    private func save() {
        do {
            let followUp = try MedicalOrderService(
                context: modelContext
            ).createFollowUp(
                fromOrderId: order.id,
                patientId: patientID,
                expectedOrderRevision: order.contentRevision,
                plannedDate: date,
                items: [item],
                reason: reason,
                reminderEnabled: reminderEnabled
            )
            AppLog.data.info("Created follow-up from medical order")
            Task { @MainActor in
                let feedback: M4M5SystemFeedback?
                do {
                    let result = try await AppleReminderScheduler(
                        center: notificationCenter
                    ).scheduleFollowUpUserInitiated(followUp: followUp)
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
                onSaved(followUp, feedback)
                dismiss()
            }
        } catch {
            failed = true
            AppLog.data.error("Follow-up generation from order failed")
        }
    }
}

enum M4M5QueryLimit {
    static let standard = 500
}
