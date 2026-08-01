import SwiftData
import SwiftUI
import UIKit
import UserNotifications
#if DEBUG
import EventKit
import Photos
#endif

struct CareThreadNotificationDestination: Identifiable, Equatable {
    enum Kind: String {
        case medication
        case followUp
    }

    let id = UUID()
    let kind: Kind
    let patientID: UUID?
    let displayMode: DisplayMode

    init?(userInfo: [AnyHashable: Any], defaults: UserDefaults = .standard) {
        guard let rawKind = userInfo["carethread.kind"] as? String,
              let kind = Kind(rawValue: rawKind) else {
            return nil
        }
        self.kind = kind
        patientID = (userInfo["carethread.patient"] as? String)
            .flatMap(UUID.init(uuidString:))
        let explicitMode = (userInfo["carethread.acceptance.mode"] as? String)
            .flatMap(DisplayMode.init(rawValue:))
        let storedMode = defaults.string(forKey: DisplayMode.storageKey)
            .flatMap(DisplayMode.init(rawValue:))
        displayMode = explicitMode ?? storedMode ?? .standard
    }
}

enum CareThreadNotificationPatientResolver {
    /// Notification routes are member-scoped evidence. A missing or stale
    /// member identifier must never fall back to whichever family member is
    /// currently selected, because that could present the wrong person's
    /// medication or follow-up information.
    static func resolve(
        requestedID: UUID?,
        availablePatientIDs: Set<UUID>
    ) -> UUID? {
        guard let requestedID,
              availablePatientIDs.contains(requestedID) else {
            return nil
        }
        return requestedID
    }
}

@MainActor
final class CareThreadNotificationRouter: ObservableObject {
    static let shared = CareThreadNotificationRouter()

    @Published var destination: CareThreadNotificationDestination?

    func receive(userInfo: [AnyHashable: Any]) {
        guard let destination = CareThreadNotificationDestination(
            userInfo: userInfo
        ) else {
            AppLog.data.warning("Ignored local notification with unknown route")
            return
        }
        self.destination = destination
        AppLog.userAction.info(
            "Opened local reminder destination: \(destination.kind.rawValue)"
        )
    }
}

final class CareThreadAppDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        primeAcceptanceRouteIfRequested()
        #endif
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            CareThreadNotificationRouter.shared.receive(userInfo: userInfo)
            completionHandler()
        }
    }

    #if DEBUG
    private func primeAcceptanceRouteIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTestMode"),
              let marker = arguments.firstIndex(
                of: "-DeviceSimOpenNotificationRoute"
              ),
              arguments.indices.contains(marker + 1),
              let kind = CareThreadNotificationDestination.Kind(
                rawValue: arguments[marker + 1]
              ) else {
            return
        }
        var userInfo: [AnyHashable: Any] = [
            "carethread.kind": kind.rawValue,
            "carethread.acceptance.mode":
                DisplayMode.launchOverride?.rawValue
                    ?? DisplayMode.standard.rawValue
        ]
        if let patientMarker = arguments.firstIndex(
            of: "-DeviceSimOpenNotificationPatient"
        ), arguments.indices.contains(patientMarker + 1) {
            userInfo["carethread.patient"] = arguments[patientMarker + 1]
        }
        Task { @MainActor in
            CareThreadNotificationRouter.shared.receive(userInfo: userInfo)
        }
    }
    #endif
}

/// Keeps notification routing outside feature views so a response received
/// during cold launch is retained until SwiftData and the app-lock gate are
/// ready. The destination uses the same production screens as normal
/// navigation; elder-mode reminders deliberately land on Today.
struct CareThreadNotificationRoutingHost<Content: View>: View {
    @Query(sort: \Patient.createdAt) private var patients: [Patient]
    @ObservedObject private var router = CareThreadNotificationRouter.shared
    @ViewBuilder let content: () -> Content
    #if DEBUG
    @State private var acceptanceScheduleState = ""
    @State private var acceptancePermissionState = ""
    #endif

    var body: some View {
        content()
            .fullScreenCover(item: $router.destination) { destination in
                notificationDestination(destination)
            }
            #if DEBUG
            .overlay(alignment: .bottom) {
                if !acceptanceScheduleState.isEmpty {
                    Text(acceptanceScheduleState)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .padding(CT.Space.s2)
                        .background(CT.Color.bgElevated)
                        .accessibilityIdentifier(
                            "device.acceptance.notification.scheduled"
                        )
                }
                if !acceptancePermissionState.isEmpty {
                    Text(acceptancePermissionState)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .padding(CT.Space.s2)
                        .background(CT.Color.bgElevated)
                        .accessibilityIdentifier(
                            "device.acceptance.permission.probe"
                        )
                }
            }
            .task {
                await scheduleAcceptanceNotificationIfRequested()
                primeAcceptancePermissionIfRequested()
                await probeAcceptancePermissionIfRequested()
            }
            #endif
    }

    @ViewBuilder
    private func notificationDestination(
        _ destination: CareThreadNotificationDestination
    ) -> some View {
        if let patientID = resolvedPatientID(destination.patientID) {
            if destination.displayMode == .elder {
                ElderRootView(initialPatientID: patientID) {
                    UserDefaults.standard.set(
                        DisplayMode.standard.rawValue,
                        forKey: DisplayMode.storageKey
                    )
                    router.destination = nil
                }
                .environment(\.displayMode, DisplayMode.elder)
                .overlay(alignment: .topTrailing) {
                    Button(Copy.Common.close) {
                        router.destination = nil
                    }
                    .buttonStyle(.bordered)
                    .padding(CT.Space.s4)
                    .accessibilityIdentifier("notification.route.close")
                }
            } else {
                NavigationStack {
                    switch destination.kind {
                    case .medication:
                        MedicationAndOrdersView(patientID: patientID)
                    case .followUp:
                        FollowUpsView(patientID: patientID)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Common.close) {
                            router.destination = nil
                        }
                        .accessibilityIdentifier("notification.route.close")
                    }
                }
                .environment(\.displayMode, DisplayMode.standard)
            }
        } else {
            NavigationStack {
                ContentUnavailableView(
                    "找不到提醒对应的家人",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("这条提醒可能来自已经删除的资料。CareThread 不会改为显示其他家人的内容。")
                )
                .accessibilityIdentifier("notification.route.missingMember")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Common.close) {
                            router.destination = nil
                        }
                        .accessibilityIdentifier("notification.route.close")
                    }
                }
            }
        }
    }

    private func resolvedPatientID(_ requestedID: UUID?) -> UUID? {
        CareThreadNotificationPatientResolver.resolve(
            requestedID: requestedID,
            availablePatientIDs: Set(patients.map(\.id))
        )
    }

    #if DEBUG
    @MainActor
    private func scheduleAcceptanceNotificationIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(
            of: "-DeviceSimScheduleNotification"
        ), arguments.indices.contains(marker + 1),
              let kind = CareThreadNotificationDestination.Kind(
                rawValue: arguments[marker + 1]
              ) else {
            return
        }
        let mode = DisplayMode.launchOverride ?? .standard
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        do {
            guard try await center.requestAuthorization(
                options: [.alert, .badge, .sound]
            ) else {
                acceptanceScheduleState = "通知权限未授予"
                return
            }
            let content = UNMutableNotificationContent()
            content.title = kind == .medication
                ? Copy.System.notificationMedicationTitle
                : Copy.System.notificationFollowUpTitle
            let modeText = mode == .elder ? "长辈版" : "标准版"
            let kindText = kind == .medication ? "用药" : "复查"
            content.body = "虚构验收 · \(modeText) · \(kindText)"
            content.sound = .default
            content.userInfo = [
                "carethread.kind": kind.rawValue,
                "carethread.patient": SeedService.patientID.uuidString,
                "carethread.acceptance.mode": mode.rawValue
            ]
            try await center.add(
                UNNotificationRequest(
                    identifier: "carethread.device-acceptance.\(mode.rawValue).\(kind.rawValue)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: 5,
                        repeats: false
                    )
                )
            )
            acceptanceScheduleState = "已安排：\(content.body)"
        } catch {
            acceptanceScheduleState = "通知安排失败"
            AppLog.data.error("Device acceptance notification scheduling failed")
        }
    }

    @MainActor
    private func primeAcceptancePermissionIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(
            of: "-DeviceSimPrimePermission"
        ), arguments.indices.contains(marker + 1) else {
            return
        }
        let service = arguments[marker + 1]
        switch service {
        case "photos":
            _ = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        case "photos-add":
            _ = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        case "calendar":
            _ = EKEventStore.authorizationStatus(for: .event)
        default:
            acceptancePermissionState = "service=unknown; primed=false"
            return
        }
        acceptancePermissionState = "service=\(service); primed=true"
    }

    @MainActor
    private func probeAcceptancePermissionIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(
            of: "-DeviceSimProbePermission"
        ), arguments.indices.contains(marker + 1) else {
            return
        }
        let service = arguments[marker + 1]
        let expected = argumentValue(
            "-DeviceSimExpectedPermission",
            in: arguments
        )
        let status: String
        var calendarRoundTrip = "not-applicable"
        var systemStateConsistent = true
        switch service {
        case "photos":
            let value: PHAuthorizationStatus
            if expected == "notDetermined" {
                value = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            } else {
                let requested = await PHPhotoLibrary.requestAuthorization(
                    for: .readWrite
                )
                value = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                systemStateConsistent = photoStatus(requested)
                    == photoStatus(value)
            }
            status = photoStatus(value)
        case "photos-add":
            let value: PHAuthorizationStatus
            if expected == "notDetermined" {
                value = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            } else {
                let requested = await PHPhotoLibrary.requestAuthorization(
                    for: .addOnly
                )
                value = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                systemStateConsistent = photoStatus(requested)
                    == photoStatus(value)
            }
            status = photoStatus(value)
        case "calendar":
            var requestedFullAccess: Bool?
            if expected != "notDetermined" {
                requestedFullAccess = try? await EKEventStore()
                    .requestFullAccessToEvents()
            }
            let value = EKEventStore.authorizationStatus(for: .event)
            status = calendarStatus(value)
            if let requestedFullAccess {
                systemStateConsistent = requestedFullAccess
                    == (status == "authorized")
            }
            if value == .fullAccess {
                calendarRoundTrip = await calendarEventRoundTrip()
                    ? "true"
                    : "false"
            }
        default:
            acceptancePermissionState = "service=unknown; status=invalid"
            return
        }
        let guidance: String
        switch status {
        case "authorized":
            guidance = "权限已开启；核心资料仍只存在本机"
        case "denied":
            guidance = "权限未开启；可继续使用核心功能，稍后可去系统设置开启"
        default:
            guidance = "尚未请求权限；核心功能可继续使用"
        }
        acceptancePermissionState = [
            "service=\(service)",
            "status=\(status)",
            "systemStateConsistent=\(systemStateConsistent)",
            "calendarEventRoundTrip=\(calendarRoundTrip)",
            guidance
        ].joined(separator: "; ")
    }

    private func argumentValue(
        _ marker: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: marker),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func photoStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized, .limited: "authorized"
        case .denied, .restricted: "denied"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    private func calendarStatus(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .authorized, .fullAccess, .writeOnly: "authorized"
        case .denied, .restricted: "denied"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    @MainActor
    private func calendarEventRoundTrip() async -> Bool {
        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents else {
            return false
        }
        let token = UUID().uuidString
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "CareThread 虚构权限验收 \(token)"
        event.startDate = Date().addingTimeInterval(300)
        event.endDate = event.startDate.addingTimeInterval(900)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            let matches = store.events(
                matching: store.predicateForEvents(
                    withStart: event.startDate.addingTimeInterval(-1),
                    end: event.endDate.addingTimeInterval(1),
                    calendars: [calendar]
                )
            ).contains { $0.title == event.title }
            try store.remove(event, span: .thisEvent, commit: true)
            return matches
        } catch {
            AppLog.data.error("Device acceptance calendar round trip failed")
            return false
        }
    }
    #endif
}
