import SwiftData
import SwiftUI

struct ElderRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.createdAt) private var patients: [Patient]
    @AppStorage("carethread.selectedPatientID") private var storedPatientID = ""
    @State private var selectedPatientID: UUID?
    @State private var selectedTab = 0
    @State private var previousTab = 0
    @State private var showCapture = false
    @State private var showSettings = false
    @State private var showDoctorBrief = false
    @State private var showSwitchConfirmation = false
    @State private var recordsRefreshToken = 0

    let onSwitchToStandard: () -> Void

    init(onSwitchToStandard: @escaping () -> Void) {
        self.onSwitchToStandard = onSwitchToStandard
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                if let patientID = selectedPatient?.id {
                    ElderTodayView(
                        patientID: patientID,
                        patients: patients,
                        selectedPatientID: $selectedPatientID,
                        onSettings: { showSettings = true },
                        onDoctorBrief: { showDoctorBrief = true },
                        onCapture: { showCapture = true }
                    )
                } else {
                    elderMissingMember
                }
            }
            .tabItem {
                Label(Copy.Elder.today, systemImage: "sun.max")
            }
            .tag(0)

            Color.clear
                .tabItem {
                    Label(Copy.Elder.capture, systemImage: "doc.viewfinder")
                }
                .tag(1)

            NavigationStack {
                if let patientID = selectedPatient?.id {
                    ElderRecordsView(
                        patientID: patientID,
                        refreshToken: recordsRefreshToken
                    )
                } else {
                    elderMissingMember
                }
            }
            .tabItem {
                Label(Copy.Elder.records, systemImage: "tray.full")
            }
            .tag(2)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == 1 {
                previousTab = oldValue == 1 ? previousTab : oldValue
                showCapture = true
                selectedTab = previousTab
            } else {
                previousTab = newValue
            }
        }
        .onChange(of: selectedPatientID) { _, newValue in
            storedPatientID = newValue?.uuidString ?? ""
        }
        .sheet(isPresented: $showCapture) {
            if let patient = selectedPatient {
                ElderCaptureFlowView(
                    patient: patient,
                    onSaved: {
                        recordsRefreshToken += 1
                    },
                    onBackToday: {
                        showCapture = false
                        selectedTab = 0
                        previousTab = 0
                    }
                )
            } else {
                elderMissingMember
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ElderSettingsView(
                    onRequestStandardMode: {
                        showSettings = false
                        showSwitchConfirmation = true
                    }
                )
            }
        }
        .sheet(isPresented: $showDoctorBrief) {
            NavigationStack {
                if let patientID = selectedPatient?.id {
                    ElderDoctorBriefView(patientID: patientID)
                } else {
                    elderMissingMember
                }
            }
        }
        .fullScreenCover(isPresented: $showSwitchConfirmation) {
            ElderModeSwitchConfirmationView(
                targetMode: .standard,
                onConfirm: {
                    showSwitchConfirmation = false
                    onSwitchToStandard()
                },
                onCancel: {
                    showSwitchConfirmation = false
                }
            )
        }
        .task {
            bootstrapIfNeeded()
        }
        .dynamicTypeSize(...ElderDynamicTypePolicy.maximum)
        .tint(CT.Color.primary)
        .accessibilityIdentifier("elder.root")
    }

    private var selectedPatient: Patient? {
        patients.first(where: { $0.id == selectedPatientID })
            ?? patients.first
    }

    private var elderMissingMember: some View {
        ContentUnavailableView(
            Copy.Records.addMemberFirst,
            systemImage: "person.crop.circle.badge.plus"
        )
    }

    @MainActor
    private func bootstrapIfNeeded() {
        if patients.isEmpty {
            do {
                if ProcessInfo.processInfo.arguments.contains("-uiTestMode") {
                    if ProcessInfo.processInfo.arguments.contains(
                        "-uiTestEmpty"
                    ) {
                        let patient = Patient(
                            id: SeedService.patientID,
                            displayName: "虚构空档案",
                            reportName: "虚构空档案"
                        )
                        modelContext.insert(patient)
                        try modelContext.save()
                    } else {
                        try SeedService.seedDemo(into: modelContext)
                    }
                } else {
                    let store = InMemorySelectedMemberStore()
                    let patient = try MemberService(
                        context: modelContext,
                        vaultProvisioner: try CaptureVaultService(),
                        selectionStore: store
                    ).createMember(displayName: Copy.Records.defaultMember)
                    storedPatientID = patient.id.uuidString
                }
            } catch {
                AppLog.data.error(
                    "Elder member bootstrap failed: \(error.localizedDescription)"
                )
            }
        }
        let refreshed = (try? modelContext.fetch(
            FetchDescriptor<Patient>(sortBy: [SortDescriptor(\.createdAt)])
        )) ?? patients
        if let stored = UUID(uuidString: storedPatientID),
           refreshed.contains(where: { $0.id == stored }) {
            selectedPatientID = stored
        } else {
            selectedPatientID = refreshed.first?.id
        }
        if ProcessInfo.processInfo.arguments.contains("-M9OpenCapture") {
            showCapture = true
        }
        if ProcessInfo.processInfo.arguments.contains("-M9OpenRecords") {
            selectedTab = 2
            previousTab = 2
        }
        if ProcessInfo.processInfo.arguments.contains("-M9OpenBrief") {
            showDoctorBrief = true
        }
    }
}
