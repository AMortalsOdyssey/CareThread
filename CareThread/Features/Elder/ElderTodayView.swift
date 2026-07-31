import SwiftData
import SwiftUI

struct ElderTodayView: View {
    @Query private var medications: [Medication]
    @Query private var followUps: [FollowUp]
    @Query private var records: [MedicalRecord]

    let patientID: UUID
    let patients: [Patient]
    @Binding var selectedPatientID: UUID?
    let onSettings: () -> Void
    let onDoctorBrief: () -> Void
    let onAsk: () -> Void
    let onCapture: () -> Void

    @State private var showPendingExplanation = false

    init(
        patientID: UUID,
        patients: [Patient],
        selectedPatientID: Binding<UUID?>,
        onSettings: @escaping () -> Void,
        onDoctorBrief: @escaping () -> Void,
        onAsk: @escaping () -> Void = {},
        onCapture: @escaping () -> Void
    ) {
        self.patientID = patientID
        self.patients = patients
        _selectedPatientID = selectedPatientID
        self.onSettings = onSettings
        self.onDoctorBrief = onDoctorBrief
        self.onAsk = onAsk
        self.onCapture = onCapture
        _medications = Query(
            filter: #Predicate<Medication> { $0.patientId == patientID },
            sort: [SortDescriptor(\.startDate, order: .reverse)]
        )
        _followUps = Query(
            filter: #Predicate<FollowUp> { $0.patientId == patientID },
            sort: [SortDescriptor(\.plannedDate)]
        )
        _records = Query(
            filter: #Predicate<MedicalRecord> { $0.patientId == patientID },
            sort: [SortDescriptor(\.eventDate, order: .reverse)]
        )
    }

    private var snapshot: ElderTodaySnapshot {
        ElderTodaySnapshotBuilder.build(
            patientID: patientID,
            medications: medications,
            followUps: followUps,
            records: records,
            now: Date()
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s6) {
                dateHeader
                memberSwitcher
                Button(action: onAsk) {
                    Label("问我的资料", systemImage: "magnifyingglass")
                }
                .buttonStyle(ElderPrimaryButtonStyle())
                .accessibilityIdentifier("elder.today.ask")
                medicationSection
                if let followUp = snapshot.nextFollowUp {
                    followUpCard(followUp)
                }
                Button(action: onDoctorBrief) {
                    Label(
                        Copy.Elder.doctorBrief,
                        systemImage: "doc.plaintext.fill"
                    )
                }
                .buttonStyle(ElderPrimaryButtonStyle())
                .accessibilityIdentifier("elder.today.doctor")
                if snapshot.pendingReviewCount > 0 {
                    pendingBanner
                }
                if snapshot.medications.isEmpty {
                    Button(action: onCapture) {
                        Label(
                            Copy.Elder.capture,
                            systemImage: "doc.viewfinder"
                        )
                    }
                    .buttonStyle(ElderSecondaryButtonStyle())
                    .accessibilityIdentifier("elder.today.captureHint")
                }
            }
            .padding(CT.Space.elderScreen)
        }
        .background(CT.Color.bgBase)
        .alert(
            Copy.Elder.pendingExplanation,
            isPresented: $showPendingExplanation
        ) {
            Button(Copy.Common.acknowledge) {}
        } message: {
            Text(Copy.disclaimer)
        }
        .accessibilityIdentifier("elder.today")
        #if DEBUG
        .screenshotReady(.elderToday, when: !records.isEmpty)
        #endif
    }

    private var dateHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: CT.Space.s3) {
            Text(Self.dateHeader.string(from: Date()))
                .font(CT.Font.elderDisplay)
                .foregroundStyle(CT.Color.inkPrimary)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: CT.Space.s2)
            Button(Copy.Elder.settings, action: onSettings)
                .font(CT.Font.elderSubhead)
                .frame(minHeight: CT.Size.elderTouchTarget)
                .accessibilityIdentifier("elder.today.settings")
        }
    }

    private var memberSwitcher: some View {
        Menu {
            ForEach(patients, id: \.id) { patient in
                Button(patient.displayName) {
                    selectedPatientID = patient.id
                    AppLog.userAction.info(
                        "Elder mode switched current member"
                    )
                }
            }
        } label: {
            HStack(spacing: CT.Space.s3) {
                Image(systemName: "person.crop.circle")
                    .font(CT.Font.elderTitle2)
                VStack(alignment: .leading, spacing: CT.Space.s1) {
                    Text(Copy.Elder.currentMember)
                        .font(CT.Font.elderFootnote)
                    Text(
                        patients.first(where: { $0.id == patientID })?
                            .displayName ?? Copy.Records.defaultMember
                    )
                    .font(CT.Font.elderHeadline)
                }
                Spacer()
                Text(Copy.Elder.switchMember)
                    .font(CT.Font.elderSubhead)
                Image(systemName: "chevron.down")
            }
            .foregroundStyle(CT.Color.primaryOnContainer)
            .frame(
                maxWidth: .infinity,
                minHeight: CT.Size.elderListRowHeight,
                alignment: .leading
            )
            .padding(.horizontal, CT.Space.s4)
            .background(CT.Color.primaryContainer)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.elderCard,
                    style: .continuous
                )
            )
        }
        .accessibilityIdentifier("elder.today.member")
    }

    private var medicationSection: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            Text(Copy.Elder.medications)
                .font(CT.Font.elderTitle2)
                .foregroundStyle(CT.Color.inkPrimary)
                .accessibilityAddTraits(.isHeader)
            if snapshot.medications.isEmpty {
                ElderRecordCard {
                    Text(Copy.Elder.noMedication)
                        .font(CT.Font.elderBody)
                        .foregroundStyle(CT.Color.inkPrimary)
                        .lineSpacing(8)
                }
                .accessibilityIdentifier("elder.today.noMedication")
            } else {
                ForEach(snapshot.medications) { medication in
                    ElderRecordCard {
                        VStack(alignment: .leading, spacing: CT.Space.s3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(medication.name)
                                    .font(CT.Font.elderTitle2)
                                Spacer()
                                Text(medication.dose)
                                    .font(CT.Font.elderHeadline.monospacedDigit())
                            }
                            Text(medication.time)
                                .font(CT.Font.elderValueBig)
                                .foregroundStyle(
                                    medication.isPast
                                        ? CT.Color.inkTertiary
                                        : CT.Color.primary
                                )
                            if !medication.usage.isEmpty {
                                Text(medication.usage)
                                    .font(CT.Font.elderBody)
                                    .lineSpacing(8)
                            }
                        }
                        .foregroundStyle(CT.Color.inkPrimary)
                    }
                    .accessibilityIdentifier("elder.today.medication")
                }
            }
        }
    }

    private func followUpCard(
        _ followUp: ElderFollowUpCardSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            Text(Copy.Elder.nextFollowUp)
                .font(CT.Font.elderTitle2)
                .foregroundStyle(CT.Color.inkPrimary)
            ElderRecordCard {
                VStack(alignment: .leading, spacing: CT.Space.s2) {
                    Text(followUp.dayText)
                        .font(CT.Font.elderValueBig)
                        .foregroundStyle(
                            followUp.isOverdue
                                ? CT.Color.danger
                                : CT.Color.primary
                        )
                    Text(followUp.countdownText)
                        .font(CT.Font.elderHeadline)
                    Text(followUp.itemText)
                        .font(CT.Font.elderBody)
                        .lineSpacing(8)
                }
                .foregroundStyle(CT.Color.inkPrimary)
            }
            .accessibilityIdentifier("elder.today.followUp")
        }
    }

    private var pendingBanner: some View {
        Button {
            showPendingExplanation = true
        } label: {
            Text(
                String(
                    format: Copy.Elder.pendingReview,
                    snapshot.pendingReviewCount
                )
            )
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
        .buttonStyle(.plain)
        .accessibilityIdentifier("elder.today.pending")
    }

    private static let dateHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = CTDate.calendar
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()
}
