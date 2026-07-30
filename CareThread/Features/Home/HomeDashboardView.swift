import SwiftData
import SwiftUI

struct HomeDashboardSnapshot: Equatable {
    struct Member: Equatable, Identifiable {
        var id: UUID
        var name: String
        var age: Int?
    }

    struct FollowUpItem: Equatable {
        var id: UUID
        var title: String
        var plannedDate: Date
        var dayDistance: Int

        var isOverdue: Bool { dayDistance < 0 }
    }

    struct MedicationItem: Equatable, Identifiable {
        var id: UUID
        var name: String
        var dose: String
        var times: [String]
    }

    struct RecordItem: Equatable, Identifiable {
        var id: UUID
        var type: RecordType
        var title: String
        var date: Date
        var hospital: String?
    }

    var member: Member
    var followUp: FollowUpItem?
    var medications: [MedicationItem]
    var pendingRecordCount: Int
    var recentRecordCount: Int
    var recentAbnormalCount: Int
    var recentMedicationAdjustmentCount: Int
    var recentRecords: [RecordItem]

    var isEmpty: Bool {
        followUp == nil &&
            medications.isEmpty &&
            pendingRecordCount == 0 &&
            recentRecordCount == 0
    }
}

@MainActor
struct HomeDashboardLoader {
    let context: ModelContext
    var now: () -> Date = Date.init
    var calendar: Calendar = .current

    func load(patientID: UUID) throws -> HomeDashboardSnapshot? {
        var patientDescriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == patientID }
        )
        patientDescriptor.fetchLimit = 1
        guard let patient = try context.fetch(patientDescriptor).first else {
            return nil
        }

        let referenceDate = now()
        let patientAge = AgeCalculator.age(
            birthday: patient.birthDate,
            at: referenceDate,
            manualAge: nil,
            calendar: calendar
        ).age

        var medicationDescriptor = FetchDescriptor<Medication>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        medicationDescriptor.fetchLimit = M4M5QueryLimit.standard
        let medicationRows = try context.fetch(medicationDescriptor)
        let activeMedications = medicationRows
            .filter { $0.lifecycleStatus == .active && $0.isEffective(at: referenceDate) }
            .map {
                HomeDashboardSnapshot.MedicationItem(
                    id: $0.id,
                    name: $0.name,
                    dose: Self.doseText(value: $0.doseValue, unit: $0.doseUnit),
                    times: $0.reminderTimes
                        .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
                        .map(M4M5DateFormatting.clock)
                )
            }

        let pendingFollowUp = FollowUpStatus.pending.rawValue
        var followUpDescriptor = FetchDescriptor<FollowUp>(
            predicate: #Predicate {
                $0.patientId == patientID &&
                    $0.statusRawValue == pendingFollowUp
            },
            sortBy: [SortDescriptor(\.plannedDate)]
        )
        followUpDescriptor.fetchLimit = 1
        let followUp = try context.fetch(followUpDescriptor).first
            .map {
                HomeDashboardSnapshot.FollowUpItem(
                    id: $0.id,
                    title: $0.items.joined(separator: "、"),
                    plannedDate: $0.plannedDate,
                    dayDistance: M4M5CalendarMath.dayDistance(
                        from: referenceDate,
                        to: $0.plannedDate,
                        calendar: calendar
                    )
                )
            }

        let thirtyDaysAgo = calendar.date(
            byAdding: .day,
            value: -30,
            to: referenceDate
        ) ?? referenceDate
        let recentRecordCountDescriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate {
                $0.patientId == patientID && $0.eventDate >= thirtyDaysAgo
            }
        )
        let recentRecordCount = try context.fetchCount(
            recentRecordCountDescriptor
        )
        var recordsDescriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate {
                $0.patientId == patientID && $0.eventDate >= thirtyDaysAgo
            },
            sortBy: [
                SortDescriptor(\.eventDate, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        )
        recordsDescriptor.fetchLimit = M4M5QueryLimit.standard
        let recentRecords = try context.fetch(recordsDescriptor)
        let pendingDescriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate {
                $0.patientId == patientID &&
                    $0.reviewStatusRawValue == "pending"
            }
        )
        let pendingCount = try context.fetchCount(pendingDescriptor)
        let adjustmentCount = medicationRows.filter {
            $0.previousVersionId != nil && $0.updatedAt >= thirtyDaysAgo
        }.count

        return HomeDashboardSnapshot(
            member: .init(id: patient.id, name: patient.displayName, age: patientAge),
            followUp: followUp,
            medications: activeMedications,
            pendingRecordCount: pendingCount,
            recentRecordCount: recentRecordCount,
            recentAbnormalCount: recentRecords.reduce(0) {
                $0 + $1.abnormalFlags.count
            },
            recentMedicationAdjustmentCount: adjustmentCount,
            recentRecords: recentRecords.prefix(3).map {
                .init(
                    id: $0.id,
                    type: $0.type,
                    title: $0.displayTitle,
                    date: $0.eventDate,
                    hospital: $0.hospital
                )
            }
        )
    }

    private static func doseText(value: Double?, unit: String) -> String {
        guard let value else { return unit }
        return "\(value.formatted(.number.precision(.fractionLength(0...2))))\(unit)"
    }
}

struct HomeDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.createdAt) private var patients: [Patient]
    @Binding var patientID: UUID?
    var now: () -> Date = Date.init
    var onCapture: () -> Void = {}
    var onTimeline: () -> Void = {}
    var onBrief: () -> Void = {}
    var onPendingRecords: () -> Void = {}
    var onFollowUp: (UUID) -> Void = { _ in }
    var onMedication: (UUID) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }

    @State private var snapshot: HomeDashboardSnapshot?
    @State private var loadError = false
    @State private var showExample = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CT.Space.s7) {
                header
                if let snapshot {
                    if snapshot.isEmpty {
                        emptyState
                    } else {
                        nextSection(snapshot)
                        pendingBanner(snapshot)
                        recentSection(snapshot)
                    }
                    quickActions
                } else if loadError {
                    ContentUnavailableView(
                        Copy.System.dataLoadFailed,
                        systemImage: "exclamationmark.triangle"
                    )
                } else {
                    ProgressView()
                        .frame(
                            maxWidth: .infinity,
                            minHeight: CT.Size.dashboardLoadingMinHeight
                        )
                }
                Text(Copy.disclaimer)
                    .font(CT.Font.label)
                    .foregroundStyle(CT.Color.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(CT.Space.s4)
        }
        .background(CT.Color.bgBase)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: patientID) {
            load()
        }
        .refreshable {
            load()
        }
        .sheet(isPresented: $showExample) {
            HomeRecordExampleView()
        }
        .accessibilityIdentifier("m45.home")
    }

    private var selectedPatient: Patient? {
        patients.first(where: { $0.id == patientID }) ?? patients.first
    }

    private var header: some View {
        HStack(alignment: .top, spacing: CT.Space.s3) {
            VStack(alignment: .leading, spacing: CT.Space.s1) {
                Text(M4M5CalendarMath.greeting(at: now()))
                    .font(CT.Font.title1)
                    .foregroundStyle(CT.Color.inkPrimary)
                Text(M4M5DateFormatting.weekday.string(from: now()))
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
            Spacer()
            Menu {
                ForEach(patients) { patient in
                    Button {
                        patientID = patient.id
                    } label: {
                        if patient.id == selectedPatient?.id {
                            Label(patient.displayName, systemImage: "checkmark")
                        } else {
                            Text(patient.displayName)
                        }
                    }
                }
                if let selectedPatient {
                    Divider()
                    Button {
                        onProfile(selectedPatient.id)
                    } label: {
                        Label(Copy.Manage.profile, systemImage: "person.text.rectangle")
                    }
                }
            } label: {
                HStack(spacing: CT.Space.s2) {
                    Image(systemName: "person.crop.circle")
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Text(snapshot?.member.name ?? selectedPatient?.displayName ?? Copy.Home.memberPicker)
                            .lineLimit(1)
                        if let age = snapshot?.member.age {
                            Text(String(format: Copy.Home.ageFormat, age))
                                .font(CT.Font.caption)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(CT.Font.subhead)
                .foregroundStyle(CT.Color.primaryOnContainer)
                .padding(.horizontal, CT.Space.s3)
                .frame(minHeight: CT.Size.secondaryButtonHeight)
                .background(CT.Color.primaryContainer)
                .clipShape(Capsule())
            }
            .accessibilityLabel(Copy.Home.memberPicker)
            .accessibilityIdentifier("m45.home.member")
        }
    }

    @ViewBuilder
    private func nextSection(_ value: HomeDashboardSnapshot) -> some View {
        if value.followUp != nil || !value.medications.isEmpty {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                M4M5SectionTitle(text: Copy.Home.next)
                if let followUp = value.followUp {
                    Button {
                        onFollowUp(followUp.id)
                    } label: {
                        M4M5Card(tone: followUp.isOverdue ? .danger : .primary) {
                            HStack(alignment: .center, spacing: CT.Space.s4) {
                                VStack(spacing: CT.Space.s1) {
                                    Text(followUp.isOverdue ? Copy.Home.overdue : "\(followUp.dayDistance)")
                                        .font(followUp.isOverdue ? CT.Font.headline : CT.Font.valueBig)
                                    if !followUp.isOverdue {
                                        Text(Copy.Home.dayUnit)
                                            .font(CT.Font.caption)
                                    }
                                }
                                .foregroundStyle(followUp.isOverdue ? CT.Color.dangerOnContainer : CT.Color.primaryOnContainer)
                                VStack(alignment: .leading, spacing: CT.Space.s1) {
                                    Text(followUp.title)
                                        .font(CT.Font.headline)
                                        .foregroundStyle(CT.Color.inkPrimary)
                                    Text("\(M4M5DateFormatting.fullDay.string(from: followUp.plannedDate)) · \(Copy.Home.viewPreparation) ›")
                                        .font(CT.Font.footnote)
                                        .foregroundStyle(CT.Color.inkSecondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("m45.home.followup")
                }
                ForEach(value.medications) { medication in
                    Button {
                        onMedication(medication.id)
                    } label: {
                        M4M5Card {
                            HStack(spacing: CT.Space.s3) {
                                Image(systemName: "pills.fill")
                                    .foregroundStyle(CT.Color.primary)
                                VStack(alignment: .leading, spacing: CT.Space.s1) {
                                    Text("\(medication.name) \(medication.dose)")
                                        .font(CT.Font.headline)
                                        .foregroundStyle(CT.Color.inkPrimary)
                                    Text(medication.times.isEmpty
                                         ? medication.name
                                         : medication.times.joined(separator: " · "))
                                        .font(CT.Font.footnote)
                                        .foregroundStyle(CT.Color.inkSecondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("m45.home.medication.\(medication.id.uuidString)")
                }
            }
        }
    }

    @ViewBuilder
    private func pendingBanner(_ value: HomeDashboardSnapshot) -> some View {
        if value.pendingRecordCount > 0 {
            Button(action: onPendingRecords) {
                M4M5StatusBanner(
                    message: String(
                        format: Copy.Home.pendingFormat,
                        value.pendingRecordCount
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("m45.home.pending")
        }
    }

    @ViewBuilder
    private func recentSection(_ value: HomeDashboardSnapshot) -> some View {
        if value.recentRecordCount > 0 {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                M4M5SectionTitle(text: Copy.Home.recentThirtyDays)
                Button(action: onTimeline) {
                    Text(
                        String(
                            format: Copy.Home.recentSummaryFormat,
                            value.recentRecordCount,
                            value.recentAbnormalCount,
                            value.recentMedicationAdjustmentCount
                        )
                    )
                    .font(CT.Font.subhead)
                    .foregroundStyle(CT.Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                ForEach(value.recentRecords) { record in
                    M4M5Card {
                        HStack(alignment: .top, spacing: CT.Space.s3) {
                            Image(systemName: record.type == .lab ? "testtube.2" : "doc.text")
                                .foregroundStyle(CT.Color.primary)
                            VStack(alignment: .leading, spacing: CT.Space.s1) {
                                Text(record.title)
                                    .font(CT.Font.headline)
                                    .foregroundStyle(CT.Color.inkPrimary)
                                Text(
                                    [M4M5DateFormatting.day.string(from: record.date), record.hospital]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                )
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.inkSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            M4M5SectionTitle(text: Copy.Home.quickActions)
            HStack(alignment: .top, spacing: CT.Space.s2) {
                quickAction(Copy.Home.capture, symbol: "plus.viewfinder", id: "capture", action: onCapture)
                quickAction(Copy.Home.timeline, symbol: "calendar.day.timeline.left", id: "timeline", action: onTimeline)
                quickAction(Copy.Home.brief, symbol: "doc.text.magnifyingglass", id: "brief", action: onBrief)
            }
        }
    }

    private func quickAction(
        _ title: String,
        symbol: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: CT.Space.s2) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(CT.Font.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(CT.Color.primaryOnContainer)
            .frame(maxWidth: .infinity)
            .frame(minHeight: CT.Size.dashboardQuickActionMinHeight)
            .padding(.horizontal, CT.Space.s1)
            .background(CT.Color.primaryContainer)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("m45.home.quick.\(id)")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(Copy.Home.emptyTitle, systemImage: "doc.badge.plus")
        } description: {
            Text(Copy.Home.emptyDescription)
        } actions: {
            VStack(spacing: CT.Space.s2) {
                Button(Copy.Home.emptyCapture, action: onCapture)
                    .buttonStyle(.borderedProminent)
                Button(Copy.Home.viewExample) {
                    showExample = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(CT.Color.primary)
                .frame(minHeight: CT.Size.secondaryButtonHeight)
                .accessibilityIdentifier("m45.home.example")
            }
        }
        .accessibilityIdentifier("m45.home.empty")
    }

    @MainActor
    private func load() {
        guard let patientID = patientID ?? patients.first?.id else {
            snapshot = nil
            loadError = false
            return
        }
        if self.patientID == nil {
            self.patientID = patientID
        }
        do {
            snapshot = try HomeDashboardLoader(
                context: modelContext,
                now: now
            ).load(patientID: patientID)
            loadError = false
        } catch {
            snapshot = nil
            loadError = true
            AppLog.data.error("Home dashboard load failed for selected member")
        }
    }
}

private struct HomeRecordExampleView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                CTCard {
                    VStack(alignment: .leading, spacing: CT.Space.s3) {
                        Label(
                            Copy.Home.exampleRecordTitle,
                            systemImage: "testtube.2"
                        )
                        .font(CT.Font.title2)
                        .foregroundStyle(CT.Color.inkPrimary)
                        Text(Copy.Home.exampleRecordMeta)
                            .font(CT.Font.subhead)
                            .foregroundStyle(CT.Color.inkSecondary)
                        Text(Copy.Home.exampleRecordSummary)
                            .font(CT.Font.bodyReading)
                            .foregroundStyle(CT.Color.inkPrimary)
                    }
                }
                .padding(CT.Space.s4)
            }
            .background(CT.Color.bgBase)
            .navigationTitle(Copy.Home.exampleTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.done) {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("m45.home.exampleSheet")
    }
}
