import SwiftData
import SwiftUI

enum ElderInitialPatientSelection {
    static func resolve(
        initialPatientID: UUID?,
        storedPatientID: UUID?,
        availablePatientIDs: [UUID]
    ) -> UUID? {
        if let initialPatientID {
            return availablePatientIDs.contains(initialPatientID)
                ? initialPatientID
                : nil
        }
        if let storedPatientID,
           availablePatientIDs.contains(storedPatientID) {
            return storedPatientID
        }
        return availablePatientIDs.first
    }
}

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
    @State private var showLocalAsk = false
    @State private var showSwitchConfirmation = false
    @State private var recordsRefreshToken = 0
    #if DEBUG
    @State private var didApplyScreenshotRoute = false
    #endif

    let initialPatientID: UUID?
    let onSwitchToStandard: () -> Void

    init(
        initialPatientID: UUID? = nil,
        onSwitchToStandard: @escaping () -> Void
    ) {
        self.initialPatientID = initialPatientID
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
                        onAsk: { showLocalAsk = true },
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
        .sheet(isPresented: $showLocalAsk) {
            NavigationStack {
                if let patientID = selectedPatient?.id {
                    LocalAskView(patientID: patientID, mode: .elder)
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
        if let selectedPatientID {
            return patients.first(where: { $0.id == selectedPatientID })
        }
        if let initialPatientID {
            return patients.first(where: { $0.id == initialPatientID })
        }
        return patients.first
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
                        try SeedService.seedDemo(
                            into: modelContext,
                            vault: try CaptureVaultService()
                        )
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
        selectedPatientID = ElderInitialPatientSelection.resolve(
            initialPatientID: initialPatientID,
            storedPatientID: UUID(uuidString: storedPatientID),
            availablePatientIDs: refreshed.map(\.id)
        )
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
        #if DEBUG
        applyScreenshotRouteIfNeeded()
        #endif
    }

    #if DEBUG
    @MainActor
    private func applyScreenshotRouteIfNeeded() {
        guard !didApplyScreenshotRoute,
              let route = ScreenshotRoute.current,
              route.isElder else {
            return
        }
        didApplyScreenshotRoute = true
        switch route {
        case .elderToday:
            selectedTab = 0
            previousTab = 0
        case .elderCaptureQuestion:
            selectedTab = 0
            previousTab = 0
            showCapture = true
        case .elderRecords:
            selectedTab = 2
            previousTab = 2
        case .elderBrief:
            selectedTab = 0
            previousTab = 0
            showDoctorBrief = true
        default:
            return
        }
    }
    #endif
}
