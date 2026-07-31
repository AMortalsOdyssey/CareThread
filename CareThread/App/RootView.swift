import SwiftUI
import SwiftData

struct RootView: View {
    @AppStorage(DisplayMode.storageKey) private var storedMode = DisplayMode.standard.rawValue
    @AppStorage(AppearanceMode.storageKey)
    private var storedAppearance = AppearanceMode.system.rawValue
    @AppStorage(CareThreadOnboardingLaunchPolicy.completionKey)
    private var onboardingCompleted = false
    @AppStorage(LegalAgreement.acceptedTermsVersionKey)
    private var acceptedTermsVersion = ""
    @State private var completedResetOnboardingThisLaunch = false
    @State private var showLegalUpdateNotice = false

    private var displayMode: DisplayMode {
        DisplayMode.launchOverride ?? DisplayMode(rawValue: storedMode) ?? .standard
    }

    private var shouldPresentOnboarding: Bool {
        #if DEBUG
        if ScreenshotRoute.current == .onboarding {
            return true
        }
        #endif
        let policy = CareThreadOnboardingLaunchPolicy()
        if policy.resetOnboarding {
            return !completedResetOnboardingThisLaunch
        }
        // Deterministic feature/UI routes explicitly select a mode and are not
        // first-launch acceptance tests. The dedicated reset route exercises
        // onboarding without weakening the real first-launch behavior.
        return !onboardingCompleted && DisplayMode.launchOverride == nil
    }

    private var appearance: AppearanceMode {
        AppearanceMode.effective(storedRawValue: storedAppearance)
    }

    var body: some View {
        Group {
            if shouldPresentOnboarding {
                CareThreadOnboardingView { selectedMode in
                    storedMode = selectedMode.rawValue
                    completedResetOnboardingThisLaunch = true
                }
            } else {
                switch displayMode {
                case .standard:
                    StandardRootTabView()
                case .elder:
                    ElderRootView {
                        storedMode = DisplayMode.standard.rawValue
                    }
                }
            }
        }
        .environment(\.displayMode, displayMode)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .preferredColorScheme(appearance.colorScheme)
        .tint(CT.Color.primary)
        .task(id: onboardingCompleted) {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let debugForcesNotice = arguments.contains(
                "-LegalPresentUpdate"
            )
            let isUnrelatedAutomationRoute = arguments.contains("-uiTestMode")
                && !debugForcesNotice
            #else
            let debugForcesNotice = false
            let isUnrelatedAutomationRoute = false
            #endif
            showLegalUpdateNotice = !isUnrelatedAutomationRoute
                && (debugForcesNotice || LegalAgreement.requiresUpdateNotice(
                    onboardingCompleted: onboardingCompleted,
                    acceptedVersion: acceptedTermsVersion
                ))
        }
        .sheet(isPresented: $showLegalUpdateNotice) {
            LegalUpdateNoticeView {
                acceptedTermsVersion = LegalAgreement.currentTermsVersion
                showLegalUpdateNotice = false
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ScreenshotRoute.current == .onboarding {
                ScreenshotReadyMarker(route: .onboarding)
            }
        }
        #endif
    }
}

private struct StandardRootTabView: View {
    private enum ManagementRoute: Hashable {
        case medications
        case followUps
        case memberManagement
        case backup
        case appLock
        case appearance
        case about
    }

    private enum RecordRoute: Hashable {
        case detail(UUID)
    }

    private struct OriginalViewerRoute: Identifiable {
        let recordID: UUID
        let attachmentID: UUID
        var id: UUID { attachmentID }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.createdAt) private var patients: [Patient]
    @AppStorage(DisplayMode.storageKey) private var storedMode = DisplayMode.standard.rawValue
    @AppStorage("carethread.selectedPatientID") private var storedPatientID = ""
    @State private var selectedPatientID: UUID?
    @State private var selectedTab = 0
    @State private var previousContentTab = 0
    @State private var showCapture = false
    @State private var captureInitialSource: M3CaptureSource?
    @State private var showMoreTools = false
    @State private var showBrief = false
    @State private var showComparison = false
    @State private var showNearbySync = false
    @State private var showElderModeConfirmation = false
    @State private var recordsRefreshToken = 0
    @State private var managementPath: [ManagementRoute] = []
    @State private var recordPath: [RecordRoute] = []
    @State private var originalViewerRoute: OriginalViewerRoute?
    @State private var briefInitialRange: DateRangePreset = .sixMonths
    #if DEBUG
    @State private var didApplyScreenshotRoute = false
    #endif

    private var notificationCenter:
        any LocalNotificationCenterAdapting {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-M45NotificationDenied"
        ) {
            return M4M5DeniedNotificationCenter()
        }
        #endif
        return SystemLocalNotificationCenter()
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeDashboardView(
                    patientID: $selectedPatientID,
                    onCapture: { showCapture = true },
                    onTimeline: { selectedTab = 1 },
                    onBrief: { showBrief = true },
                    onPendingRecords: { selectedTab = 3 },
                    onFollowUp: { _ in openManagement(.followUps) },
                    onMedication: { _ in openManagement(.medications) }
                )
                #if DEBUG
                .screenshotReady(.home)
                #endif
            }
            .tabItem { Label(Copy.Tab.home, systemImage: "house") }
            .tag(0)

            NavigationStack {
                if let patientID = selectedPatient?.id {
                    TimelineView(
                        patientID: patientID,
                        onSelect: { destination in
                            openTimelineDestination(destination)
                        }
                    )
                    #if DEBUG
                    .screenshotReady(.timeline)
                    #endif
                } else {
                    ContentUnavailableView(
                        Copy.Records.addMemberFirst,
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
            }
            .tabItem { Label(Copy.Tab.timeline, systemImage: "calendar.day.timeline.left") }
            .tag(1)

            Color.clear
            .tabItem { Label(Copy.Tab.capture, systemImage: "plus.circle.fill") }
            .tag(2)

            NavigationStack(path: $recordPath) {
                RecordLibraryView(
                    patientID: $selectedPatientID,
                    patients: patients,
                    refreshToken: recordsRefreshToken
                )
                .navigationDestination(for: RecordRoute.self) { route in
                    switch route {
                    case let .detail(recordID):
                        if let record = fetchRecord(id: recordID) {
                            RecordDetailView(record: record) {
                                recordsRefreshToken += 1
                            }
                            #if DEBUG
                            .screenshotReady(.recordDetail)
                            #endif
                        } else {
                            ProgressView(Copy.Records.loading)
                        }
                    }
                }
            }
            .tabItem { Label(Copy.Tab.records, systemImage: "tray.full") }
            .tag(3)

            NavigationStack(path: $managementPath) {
                if let patientID = selectedPatient?.id {
                    ManagementHubView(
                        patientID: patientID,
                        notificationCenter: notificationCenter,
                        onSwitchToElder: {
                            showElderModeConfirmation = true
                        },
                        onBrief: { showBrief = true },
                        onProfile: {
                            openManagement(.memberManagement)
                        },
                        onBackup: { openManagement(.backup) },
                        onAppLock: { openManagement(.appLock) },
                        onAbout: { openManagement(.about) },
                        onCaptureReport: { _ in
                            showCapture = true
                        }
                    )
                    #if DEBUG
                    .screenshotReady(.manage)
                    #endif
                    .navigationDestination(for: ManagementRoute.self) { route in
                        switch route {
                        case .medications:
                            MedicationAndOrdersView(
                                patientID: patientID,
                                notificationCenter: notificationCenter
                            )
                            #if DEBUG
                            .screenshotReady(.medications)
                            #endif
                        case .followUps:
                            FollowUpsView(
                                patientID: patientID,
                                notificationCenter: notificationCenter,
                                onCaptureReport: { _ in
                                    showCapture = true
                                }
                            )
                            #if DEBUG
                            .screenshotReady(.followups)
                            #endif
                        case .memberManagement:
                            MemberManagementView(
                                selectedPatientID: $selectedPatientID
                            )
                            #if DEBUG
                            .screenshotReady(.memberManagement)
                            #endif
                        case .backup:
                            BackupRestoreView(patientID: patientID)
                            #if DEBUG
                            .screenshotReady(.backup)
                            #endif
                        case .appLock:
                            AppLockSettingsView()
                        case .appearance:
                            AppearanceSettingsView()
                        case .about:
                            AboutCareThreadView(usesLargeType: false)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        Copy.Records.addMemberFirst,
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
            }
            .tabItem { Label(Copy.Tab.manage, systemImage: "heart.text.square") }
            .tag(4)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == 2 {
                if oldValue != 2 {
                    previousContentTab = oldValue
                }
                showMoreTools = true
                selectedTab = previousContentTab
            } else {
                previousContentTab = newValue
            }
        }
        .onChange(of: selectedPatientID) { _, newValue in
            storedPatientID = newValue?.uuidString ?? ""
        }
        .sheet(
            isPresented: $showCapture,
            onDismiss: { captureInitialSource = nil }
        ) {
            if let patient = selectedPatient {
                CaptureFlowHost(
                    patient: patient,
                    initialSource: captureInitialSource,
                    onSwitchMember: { newPatientID in
                        selectedPatientID = newPatientID
                    },
                    onSaved: {
                        recordsRefreshToken += 1
                    }
                )
            } else {
                ContentUnavailableView(
                    Copy.Records.addMemberFirst,
                    systemImage: "person.crop.circle.badge.plus"
                )
            }
        }
        .sheet(isPresented: $showMoreTools) {
            MoreQuickActionsSheet(
                onCamera: { openCapture(source: .camera) },
                onPhotos: { openCapture(source: .photos) },
                onFiles: { openCapture(source: .files) },
                onManualRecord: { openCapture(source: .manual) },
                onMedication: { openManagement(.medications) },
                onFollowUp: { openManagement(.followUps) },
                onSystemCalendar: { openManagement(.followUps) },
                onExport: { showBrief = true },
                onCompare: { showComparison = true },
                onTransfer: { showNearbySync = true }
            )
            #if DEBUG
            .screenshotReady(.more)
            #endif
        }
        .sheet(isPresented: $showBrief) {
            NavigationStack {
                if let patientID = selectedPatient?.id {
                    BriefWorkspaceView(
                        patientID: patientID,
                        initialRangePreset: briefInitialRange
                    )
                } else {
                    ContentUnavailableView(
                        Copy.Records.addMemberFirst,
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
            }
        }
        .sheet(isPresented: $showComparison) {
            NavigationStack {
                if let patientID = selectedPatient?.id {
                    LocalComparisonView(patientID: patientID)
                } else {
                    ContentUnavailableView(
                        Copy.Records.addMemberFirst,
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
            }
        }
        .sheet(isPresented: $showNearbySync) {
            NearbySyncFlowHost(
                patients: patients,
                selectedPatientID: selectedPatient?.id,
                onImportCompleted: {
                    recordsRefreshToken += 1
                    bootstrapM3IfNeeded()
                }
            )
            #if DEBUG
            .screenshotReady(.nearbySync)
            #endif
        }
        .fullScreenCover(item: $originalViewerRoute) { target in
            if let record = fetchRecord(id: target.recordID) {
                OriginalViewer(
                    record: record,
                    initialAttachmentID: target.attachmentID,
                    initialSegment: .ocr
                )
                #if DEBUG
                .screenshotReady(.originalOCR)
                #endif
            } else {
                ContentUnavailableView(
                    Copy.Records.missingOriginal,
                    systemImage: "doc.questionmark"
                )
            }
        }
        .fullScreenCover(isPresented: $showElderModeConfirmation) {
            ElderModeSwitchConfirmationView(
                targetMode: .elder,
                onConfirm: {
                    showElderModeConfirmation = false
                    storedMode = DisplayMode.elder.rawValue
                },
                onCancel: {
                    showElderModeConfirmation = false
                }
            )
        }
        .task {
            bootstrapM3IfNeeded()
        }
        .accessibilityIdentifier("standardRoot")
    }

    private var selectedPatient: Patient? {
        patients.first(where: { $0.id == selectedPatientID }) ?? patients.first
    }

    private func openCapture(source: M3CaptureSource? = nil) {
        captureInitialSource = source
        showCapture = true
    }

    @MainActor
    private func bootstrapM3IfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        if patients.isEmpty {
            do {
                if arguments.contains("-uiTestMode") {
                    if arguments.contains("-uiTestEmpty") {
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
                    let selection = InMemorySelectedMemberStore()
                    let vault = try CaptureVaultService()
                    let service = MemberService(
                        context: modelContext,
                        vaultProvisioner: vault,
                        selectionStore: selection
                    )
                    let patient = try service.createMember(
                        displayName: Copy.Records.defaultMember
                    )
                    storedPatientID = patient.id.uuidString
                }
            } catch {
                AppLog.data.error("M3 member bootstrap failed")
            }
        }
        let refreshedPatients = (try? modelContext.fetch(FetchDescriptor<Patient>())) ?? patients
        if let stored = UUID(uuidString: storedPatientID),
           refreshedPatients.contains(where: { $0.id == stored }) {
            selectedPatientID = stored
        } else {
            selectedPatientID = refreshedPatients.first?.id
        }
        if arguments.contains("-M3StressRecords"),
           refreshedPatients.contains(where: { $0.id == SeedService.patientID }) {
            let patientID = SeedService.patientID
            let countDescriptor = FetchDescriptor<MedicalRecord>(
                predicate: #Predicate { $0.patientId == patientID }
            )
            if ((try? modelContext.fetchCount(countDescriptor)) ?? 0) < 60 {
                try? SeedService.seedStress(61, into: modelContext)
            }
        }
        if arguments.contains("-M3SeedMachineRecord"),
           let patientID = selectedPatientID ?? refreshedPatients.first?.id {
            seedM3MachineRecordIfNeeded(patientID: patientID)
        }
        if arguments.contains("-M3OpenRecords") {
            selectedTab = 3
            previousContentTab = 3
        }
        if arguments.contains("-M3OpenCapture") {
            showCapture = true
        }
        if arguments.contains("-M45OpenHome") {
            selectedTab = 0
            previousContentTab = 0
        } else if arguments.contains("-M45OpenMedication") {
            openManagement(.medications)
        } else if arguments.contains("-M45OpenFollowUps") {
            openManagement(.followUps)
        }
        if arguments.contains("-M8OpenBackup") {
            openManagement(.backup)
        } else if arguments.contains("-M8OpenAppLock") {
            openManagement(.appLock)
        }
        if arguments.contains("-MemberOpenManagement") {
            openManagement(.memberManagement)
        }
        if arguments.contains("-M7OpenBrief") {
            showBrief = true
        }
        #if DEBUG
        applyScreenshotRouteIfNeeded()
        #endif
    }

    private func openManagement(_ route: ManagementRoute) {
        selectedTab = 4
        previousContentTab = 4
        managementPath = [route]
    }

    private func openTimelineDestination(
        _ destination: TimelineEvent.Destination
    ) {
        switch destination {
        case .record:
            selectedTab = 3
            previousContentTab = 3
        case .medication, .medicalOrder:
            openManagement(.medications)
        case .followUp:
            openManagement(.followUps)
        }
    }

    @MainActor
    private func fetchRecord(id: UUID) -> MedicalRecord? {
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    #if DEBUG
    @MainActor
    private func applyScreenshotRouteIfNeeded() {
        guard !didApplyScreenshotRoute,
              let route = ScreenshotRoute.current,
              !route.isElder,
              route != .onboarding,
              route != .lock else {
            return
        }
        didApplyScreenshotRoute = true
        switch route {
        case .home:
            selectedTab = 0
            previousContentTab = 0
        case .timeline:
            selectedTab = 1
            previousContentTab = 1
        case .records:
            selectedTab = 3
            previousContentTab = 3
        case .manage:
            selectedTab = 4
            previousContentTab = 4
            managementPath = []
        case .captureSource:
            captureInitialSource = nil
            showCapture = true
        case .captureConfirmation:
            captureInitialSource = .manual
            showCapture = true
        case .medications:
            openManagement(.medications)
        case .followups:
            openManagement(.followUps)
        case .backup:
            openManagement(.backup)
        case .memberManagement:
            openManagement(.memberManagement)
        case .brief:
            briefInitialRange = .sixMonths
            showBrief = true
        case .export:
            briefInitialRange = .all
            showBrief = true
        case .comparison:
            showComparison = true
        case .nearbySync:
            showNearbySync = true
        case .more:
            selectedTab = 0
            previousContentTab = 0
            showMoreTools = true
        case .recordDetail:
            if let record = screenshotLabRecord() {
                selectedTab = 3
                previousContentTab = 3
                recordPath = [.detail(record.id)]
            }
        case .originalOCR:
            if let record = screenshotLabRecord(),
               let attachment = record.attachments
                .sorted(by: { $0.pageIndex < $1.pageIndex })
                .first {
                selectedTab = 3
                previousContentTab = 3
                originalViewerRoute = OriginalViewerRoute(
                    recordID: record.id,
                    attachmentID: attachment.id
                )
            }
        case .onboarding, .lock, .elderToday, .elderCaptureQuestion,
             .elderRecords, .elderBrief:
            return
        }
    }

    @MainActor
    private func screenshotLabRecord() -> MedicalRecord? {
        let patientID = selectedPatientID ?? SeedService.patientID
        let descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [
                SortDescriptor(\.eventDate, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.first {
            $0.type == .lab
                && $0.ocrText?.isEmpty == false
                && !$0.attachments.isEmpty
        } ?? records.first
    }
    #endif

    @MainActor
    private func seedM3MachineRecordIfNeeded(patientID: UUID) {
        let title = "M3 机器识别测试"
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate {
                $0.patientId == patientID && $0.title == title
            }
        )
        descriptor.fetchLimit = 1
        guard ((try? modelContext.fetch(descriptor)) ?? []).isEmpty else { return }
        let machine = ExtractionResult(
            type: .lab,
            typeConfidence: .high,
            eventDate: CTDate.make(2026, 7, 1),
            eventDateConfidence: .high,
            hospital: "虚构市中心医院",
            department: "检验科",
            title: title,
            summary: "机器原始摘要",
            labItems: [],
            abnormalFlags: [],
            structuredFields: [],
            medicationHints: [],
            followUpHints: [],
            engineIdentifier: "ui-test-local"
        )
        modelContext.insert(
            MedicalRecord(
                patientId: patientID,
                type: .lab,
                title: title,
                summary: "用户确认摘要",
                eventDate: CTDate.make(2026, 7, 1),
                hospital: "虚构市中心医院",
                sourceType: .fixture,
                machineExtractionRevision: 1,
                confirmedRevision: 1,
                confirmedAt: Date(),
                machineExtraction: machine,
                reviewStatus: .confirmed
            )
        )
        try? modelContext.save()
    }
}
