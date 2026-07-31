import SwiftData
import SwiftUI

struct ManagementSummary: Equatable {
    var activeMedicationCount: Int
    var nextFollowUpDate: Date?
    var nextFollowUpTitle: String?
}

@MainActor
struct ManagementSummaryLoader {
    let context: ModelContext
    var now: () -> Date = Date.init

    func load(patientID: UUID) throws -> ManagementSummary {
        var medications = FetchDescriptor<Medication>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        medications.fetchLimit = M4M5QueryLimit.standard
        let medicationCount = try context.fetch(medications).filter {
            $0.lifecycleStatus == .active && $0.isEffective(at: now())
        }.count

        var followUps = FetchDescriptor<FollowUp>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\.plannedDate)]
        )
        followUps.fetchLimit = M4M5QueryLimit.standard
        let next = try context.fetch(followUps).first {
            $0.status == .pending
        }
        return ManagementSummary(
            activeMedicationCount: medicationCount,
            nextFollowUpDate: next?.plannedDate,
            nextFollowUpTitle: next?.items.joined(separator: "、")
        )
    }
}

struct ManagementHubView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppearanceMode.storageKey)
    private var storedAppearance = AppearanceMode.system.rawValue
    let patientID: UUID
    var notificationCenter: any LocalNotificationCenterAdapting =
        M4M5RuntimeAdapters.localNotificationCenter()
    var calendarStore: any CalendarEventStoreAdapting =
        SystemCalendarEventStore()
    var onSwitchToElder: () -> Void = {}
    var onBrief: () -> Void = {}
    var onProfile: () -> Void = {}
    var onBackup: () -> Void = {}
    var onAppLock: () -> Void = {}
    var onAbout: () -> Void = {}
    var onCaptureReport: (UUID) -> Void = { _ in }

    @State private var summary = ManagementSummary(
        activeMedicationCount: 0
    )
    @State private var loadFailed = false
    @State private var activityHistory = CareActivityHistory()

    var body: some View {
        List {
            Section {
                Button(action: onSwitchToElder) {
                    HStack(spacing: CT.Space.s3) {
                        Image(systemName: "textformat.size")
                            .font(CT.Font.title3)
                            .frame(
                                width: CT.Size.leadingIcon,
                                height: CT.Size.leadingIcon
                            )
                        VStack(alignment: .leading, spacing: CT.Space.s1) {
                            Text(Copy.Manage.elderTitle)
                                .font(CT.Font.headline)
                            Text(Copy.Manage.elderDescription)
                                .font(CT.Font.footnote)
                        }
                        Spacer()
                        Text(Copy.Manage.switchMode)
                            .font(CT.Font.subhead.weight(.semibold))
                    }
                    .foregroundStyle(CT.Color.primaryOnContainer)
                    .padding(.vertical, CT.Space.s3)
                }
                .listRowBackground(CT.Color.primaryContainer)
                .accessibilityIdentifier("m45.manage.elder")
            }
            if loadFailed {
                M4M5StatusBanner(
                    message: Copy.System.dataLoadFailed,
                    isDanger: true
                )
                .listRowBackground(Color.clear)
            }
            Section {
                NavigationLink {
                    MedicationAndOrdersView(
                        patientID: patientID,
                        notificationCenter: notificationCenter
                    )
                } label: {
                    M4M5IconRow(
                        title: Copy.Manage.medication,
                        subtitle: String(
                            format: Copy.Manage.medicationCountFormat,
                            summary.activeMedicationCount
                        ),
                        systemImage: "pills.fill",
                        showsChevron: false
                    )
                }
                .accessibilityIdentifier("m45.manage.medication")

                NavigationLink {
                    FollowUpsView(
                        patientID: patientID,
                        notificationCenter: notificationCenter,
                        calendarStore: calendarStore,
                        onCaptureReport: onCaptureReport
                    )
                } label: {
                    M4M5IconRow(
                        title: Copy.Manage.followUp,
                        subtitle: followUpSubtitle,
                        systemImage: "calendar.badge.clock",
                        showsChevron: false
                    )
                }
                .accessibilityIdentifier("m45.manage.followup")

                managementButton(
                    title: Copy.Manage.brief,
                    symbol: "doc.text.magnifyingglass",
                    action: onBrief
                )
                managementButton(
                    title: Copy.Manage.profile,
                    symbol: "person.text.rectangle",
                    action: onProfile
                )
                managementButton(
                    title: Copy.Manage.backup,
                    subtitle: continuitySubtitle,
                    symbol: "externaldrive.badge.plus",
                    action: onBackup
                )
                managementButton(
                    title: Copy.Manage.appLock,
                    symbol: "lock.shield",
                    action: onAppLock
                )
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    M4M5IconRow(
                        title: Copy.Manage.appearance,
                        subtitle: currentAppearance.displayName,
                        systemImage: currentAppearance.symbol,
                        showsChevron: false
                    )
                }
                .accessibilityIdentifier("m45.manage.appearance")
                managementButton(
                    title: Copy.Manage.about,
                    symbol: "info.circle",
                    action: onAbout
                )
            }
            Section {
                Text(Copy.Manage.localOnly)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
                Text(Copy.disclaimer)
                    .font(CT.Font.label)
                    .foregroundStyle(CT.Color.inkTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Manage.navigationTitle)
        .task(id: patientID) {
            reload()
        }
        .refreshable {
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .careActivityHistoryDidChange
            )
        ) { _ in
            activityHistory = CareActivityHistoryStore().snapshot()
        }
        .accessibilityIdentifier("m45.manage")
    }

    private var followUpSubtitle: String? {
        guard let date = summary.nextFollowUpDate,
              let title = summary.nextFollowUpTitle else {
            return Copy.FollowUp.noPlans
        }
        return String(
            format: Copy.Manage.nextFollowUpFormat,
            M4M5DateFormatting.day.string(from: date),
            title
        )
    }

    private func managementButton(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            M4M5IconRow(
                title: title,
                subtitle: subtitle,
                systemImage: symbol
            )
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func reload() {
        activityHistory = CareActivityHistoryStore().snapshot()
        do {
            summary = try ManagementSummaryLoader(
                context: modelContext
            ).load(patientID: patientID)
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.data.error("Management summary load failed")
        }
    }

    private var continuitySubtitle: String {
        [
            activityLine(
                Copy.Manage.lastBackup,
                date: activityHistory.lastBackupAt
            ),
            activityLine(
                Copy.Manage.lastMigration,
                date: activityHistory.lastNearbyMigrationAt
            )
        ].joined(separator: " · ")
    }

    private var currentAppearance: AppearanceMode {
        AppearanceMode(rawValue: storedAppearance) ?? .system
    }

    private func activityLine(_ label: String, date: Date?) -> String {
        guard let date else {
            return "\(label)：\(Copy.Manage.neverCompleted)"
        }
        return "\(label)：\(M4M5DateFormatting.dateAndTime.string(from: date))"
    }
}
