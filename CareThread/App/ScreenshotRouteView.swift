#if DEBUG
import SwiftData
import SwiftUI

/// Deterministic, simulator-only entry points for the 18 acceptance screenshots.
///
/// Every route renders the production feature view against the same fictional
/// `SeedService` story. The type is compiled out of release builds, so normal
/// navigation and persistence behavior cannot be changed by screenshot tooling.
enum ScreenshotRoute: String, CaseIterable {
    case onboarding
    case home
    case captureSource = "capture-source"
    case captureConfirmation = "capture-confirmation"
    case records
    case recordDetail = "record-detail"
    case originalOCR = "original-ocr"
    case medications
    case followups
    case timeline
    case brief
    case manage
    case backup
    case lock
    case elderToday = "elder-today"
    case elderCaptureQuestion = "elder-capture-question"
    case elderRecords = "elder-records"
    case elderBrief = "elder-brief"

    static var current: ScreenshotRoute? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screenshotRoute"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return ScreenshotRoute(rawValue: arguments[index + 1])
    }

    var marker: String {
        "screenshot.route.\(rawValue)"
    }
}

struct ScreenshotRouteView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.createdAt) private var patients: [Patient]

    let route: ScreenshotRoute

    @State private var selectedPatientID: UUID?
    @State private var seeded = false
    @State private var seedFailed = false

    var body: some View {
        Group {
            if route == .onboarding {
                onboarding
            } else if let patient = selectedPatient, seeded {
                routedContent(patient: patient)
            } else if seedFailed {
                ContentUnavailableView(
                    "无法载入虚构演示资料",
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView("正在准备虚构演示资料…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CT.Color.bgBase)
            }
        }
        .environment(\.displayMode, route.isElder ? .elder : .standard)
        .tint(CT.Color.primary)
        .accessibilityIdentifier(route.marker)
        .overlay(alignment: .topLeading) {
            if route == .onboarding || seeded {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(route.marker)
                    .onAppear {
                        writeReadyMarker()
                    }
            }
        }
        .task {
            prepareSeedIfNeeded()
        }
    }

    private var selectedPatient: Patient? {
        patients.first(where: { $0.id == selectedPatientID })
            ?? patients.first(where: { $0.id == SeedService.patientID })
            ?? patients.first
    }

    private var selectedRecord: MedicalRecord? {
        let patientID = SeedService.patientID
        let descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [
                SortDescriptor(\.eventDate, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        let values = (try? modelContext.fetch(descriptor)) ?? []
        return values.first(where: { $0.type == .lab })
            ?? values.first(where: { $0.reviewStatus == .confirmed })
            ?? values.first
    }

    private var originalOCRRecord: MedicalRecord? {
        let patientID = SeedService.patientID
        let title = "虚构检验原件 OCR"
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate {
                $0.patientId == patientID && $0.title == title
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private var onboarding: some View {
        CareThreadOnboardingView { _ in }
    }

    @ViewBuilder
    private func routedContent(patient: Patient) -> some View {
        switch route {
        case .onboarding:
            onboarding
        case .home:
            NavigationStack {
                HomeDashboardView(
                    patientID: $selectedPatientID,
                    onCapture: {},
                    onTimeline: {},
                    onBrief: {},
                    onPendingRecords: {},
                    onFollowUp: { _ in },
                    onMedication: { _ in }
                )
            }
        case .captureSource, .captureConfirmation:
            CaptureFlowHost(
                patient: patient,
                onSwitchMember: { selectedPatientID = $0 },
                onSaved: {}
            )
        case .records:
            NavigationStack {
                RecordLibraryView(
                    patientID: $selectedPatientID,
                    patients: patients,
                    refreshToken: 0
                )
            }
        case .recordDetail:
            NavigationStack {
                if let selectedRecord {
                    RecordDetailView(record: selectedRecord, onChanged: {})
                }
            }
        case .originalOCR:
            if let record = originalOCRRecord {
                OriginalViewer(
                    record: record,
                    initialAttachmentID: record.attachments.first?.id
                        ?? UUID(),
                    initialSegment: .ocr
                )
            }
        case .medications:
            NavigationStack {
                MedicationAndOrdersView(patientID: patient.id)
            }
        case .followups:
            NavigationStack {
                FollowUpsView(patientID: patient.id)
            }
        case .timeline:
            NavigationStack {
                TimelineView(patientID: patient.id)
            }
        case .brief:
            NavigationStack {
                BriefWorkspaceView(patientID: patient.id)
            }
        case .manage:
            NavigationStack {
                ManagementHubView(patientID: patient.id)
            }
        case .backup:
            NavigationStack {
                BackupRestoreView(patientID: patient.id)
            }
        case .lock:
            RootView()
        case .elderToday:
            NavigationStack {
                ElderTodayView(
                    patientID: patient.id,
                    patients: patients,
                    selectedPatientID: $selectedPatientID,
                    onSettings: {},
                    onDoctorBrief: {},
                    onCapture: {}
                )
            }
        case .elderCaptureQuestion:
            ElderCaptureFlowView(
                patient: patient,
                onSaved: {},
                onBackToday: {}
            )
        case .elderRecords:
            NavigationStack {
                ElderRecordsView(patientID: patient.id)
            }
        case .elderBrief:
            NavigationStack {
                ElderDoctorBriefView(patientID: patient.id)
            }
        }
    }

    @MainActor
    private func prepareSeedIfNeeded() {
        guard route != .onboarding, !seeded else { return }
        do {
            try SeedService.seedDemo(into: modelContext)
            let patientID = SeedService.patientID
            let descriptor = FetchDescriptor<MedicalRecord>(
                predicate: #Predicate {
                    $0.patientId == patientID
                }
            )
            let seededRecords = try modelContext.fetch(descriptor)
            if !seededRecords.contains(where: {
                $0.title == "虚构检验原件 OCR"
            }) {
                modelContext.insert(
                    MedicalRecord(
                        patientId: patientID,
                        type: .lab,
                        title: "虚构检验原件 OCR",
                        summary: "2 项指标，2 项异常。",
                        eventDate: CTDate.make(2026, 3, 15),
                        hospital: "四川大学华西医院",
                        department: "内分泌科",
                        sourceType: .fixture,
                        ocrText: """
                        四川大学华西医院 检验报告（虚构）
                        姓名：王晓芸
                        检验日期：2026-03-15
                        TSH 0.08 mIU/L 参考范围 0.27–4.20 ↓
                        FT4 22.8 pmol/L 参考范围 12–22 ↑
                        本页仅为虚构演示资料。
                        """,
                        reviewStatus: .confirmed
                    )
                )
            }
            try modelContext.save()
            selectedPatientID = patientID
            seeded = true
            AppLog.data.info(
                "Screenshot route ready: \(route.rawValue, privacy: .private(mask: .hash))"
            )
        } catch {
            seedFailed = true
            AppLog.data.error(
                "Screenshot seed failed for \(route.rawValue, privacy: .private(mask: .hash)); code=SCREENSHOT-SEED-0001"
            )
        }
    }

    private func writeReadyMarker() {
        let route = route
        Task {
            // Give feature-local synchronous `.task` loaders one run-loop
            // window after the AX marker becomes part of the hierarchy.
            try? await Task.sleep(for: .milliseconds(450))
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "carethread-screenshot-ready-\(route.rawValue)"
                )
            do {
                try Data(route.marker.utf8).write(
                    to: url,
                    options: .atomic
                )
                AppLog.data.info(
                    "Screenshot AX marker published: \(route.marker, privacy: .private(mask: .hash))"
                )
            } catch {
                AppLog.data.error(
                    "Screenshot readiness marker failed; code=SCREENSHOT-READY-0001"
                )
            }
        }
    }
}

private extension ScreenshotRoute {
    var isElder: Bool {
        switch self {
        case .elderToday, .elderCaptureQuestion, .elderRecords, .elderBrief:
            true
        default:
            false
        }
    }
}
#endif
