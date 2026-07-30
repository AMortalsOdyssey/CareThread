import Foundation
import UserNotifications

struct LocalNotificationRequest: Equatable {
    var identifier: String
    var fireDate: Date
    var timezoneIdentifier: String
    var title: String
    var body: String
    var userInfo: [String: String]
}

protocol LocalNotificationCenterAdapting {
    func authorizationStatus() async -> ReminderAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [LocalNotificationRequest]
    func add(_ request: LocalNotificationRequest) async throws
    func remove(identifiers: [String]) async
}

enum M4M5RuntimeAdapters {
    static func localNotificationCenter() -> any LocalNotificationCenterAdapting {
        #if DEBUG
        let environmentStatus = ProcessInfo.processInfo.environment[
            "CARETHREAD_UI_NOTIFICATION_STATUS"
        ]
        let argumentStatus = UserDefaults.standard.string(
            forKey: "M45NotificationStatus"
        )
        if environmentStatus == "denied" || argumentStatus == "denied" {
            return M4M5DeniedNotificationCenter()
        }
        #endif
        return SystemLocalNotificationCenter()
    }
}

#if DEBUG
struct M4M5DeniedNotificationCenter:
    LocalNotificationCenterAdapting {
    func authorizationStatus() async -> ReminderAuthorizationStatus {
        .denied
    }

    func requestAuthorization() async throws -> Bool {
        false
    }

    func pendingRequests() async -> [LocalNotificationRequest] {
        []
    }

    func add(_ request: LocalNotificationRequest) async throws {}

    func remove(identifiers: [String]) async {}
}
#endif

struct SystemLocalNotificationCenter: LocalNotificationCenterAdapting {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func pendingRequests() async -> [LocalNotificationRequest] {
        await center.pendingNotificationRequests().compactMap { request in
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let fireDate = trigger.nextTriggerDate() else {
                return nil
            }
            return LocalNotificationRequest(
                identifier: request.identifier,
                fireDate: fireDate,
                timezoneIdentifier: trigger.dateComponents.timeZone?.identifier ??
                    TimeZone.current.identifier,
                title: request.content.title,
                body: request.content.body,
                userInfo: request.content.userInfo.reduce(into: [:]) {
                    if let key = $1.key as? String, let value = $1.value as? String {
                        $0[key] = value
                    }
                }
            )
        }
    }

    func add(_ request: LocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = request.userInfo

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: request.timezoneIdentifier) ?? .current
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: request.fireDate
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func remove(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

enum AppleReminderSchedulingResult: Equatable {
    case scheduled(requestCount: Int, truncated: Bool)
    case disabled
    case permissionDenied(openSettingsRequired: Bool)
    case noFutureOccurrence
}

enum AppleReminderSchedulerError: Error, Equatable {
    case invalidTimezone
    case systemScheduleFailed
}

/// The system adapter is intentionally permission-silent until one of the
/// `UserInitiated` methods is called by a visible toggle or button.
struct AppleReminderScheduler {
    static let managedPrefix = "carethread."

    let center: any LocalNotificationCenterAdapting
    var now: () -> Date = Date.init
    var calendar: Calendar = .current

    init(
        center: any LocalNotificationCenterAdapting = SystemLocalNotificationCenter(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.center = center
        self.now = now
        self.calendar = calendar
    }

    func permissionStatus() async -> ReminderAuthorizationStatus {
        await center.authorizationStatus()
    }

    func scheduleMedicationUserInitiated(
        medication: Medication,
        displayName: String? = nil,
        rollingDays: Int = 30
    ) async throws -> AppleReminderSchedulingResult {
        guard medication.reminderEnabled else {
            await removeManagedRequests(reminderID: medication.id)
            return .disabled
        }
        let authorization = try await userInitiatedAuthorization()
        guard authorization else {
            return .permissionDenied(openSettingsRequired: true)
        }
        guard TimeZone(identifier: TimeZone.current.identifier) != nil else {
            throw AppleReminderSchedulerError.invalidTimezone
        }
        let pending = await center.pendingRequests()
        let capacity = availableCapacity(
            replacing: medication.id,
            pending: pending
        )
        let start = now()
        let end = calendar.date(
            byAdding: .day,
            value: max(1, min(rollingDays, 365)),
            to: start
        ) ?? start
        let plan = try ReminderPlanner.plan(
            ReminderPlanningInput(
                reminderId: medication.id,
                businessRevision: medication.contentRevision,
                frequency: medication.frequency,
                weeklyCount: medication.weeklyCount,
                reminderTimes: medication.reminderTimes,
                startDate: medication.startDate,
                endDate: medication.endDate,
                timezoneIdentifier: TimeZone.current.identifier,
                windowStart: start,
                windowEnd: end,
                systemRequestLimit: capacity
            )
        )
        let dose = [
            medication.doseValue.map {
                $0.formatted(.number.precision(.fractionLength(0...2)))
            },
            medication.doseUnit
        ]
        .compactMap { $0 }
        .joined()
        let body = String(
            format: Copy.System.notificationMedicationBodyFormat,
            medication.name,
            dose
        )
        let requests = plan.requests.map {
            LocalNotificationRequest(
                identifier: managedIdentifier(
                    reminderID: medication.id,
                    occurrenceID: $0.id
                ),
                fireDate: $0.fireDate,
                timezoneIdentifier: $0.timezoneIdentifier,
                title: Copy.System.notificationMedicationTitle,
                body: body,
                userInfo: [
                    "carethread.kind": ReminderKind.medication.rawValue,
                    "carethread.patient": medication.patientId.uuidString,
                    "carethread.medication": medication.id.uuidString,
                    "carethread.member": displayName ?? ""
                ]
            )
        }
        guard !requests.isEmpty else {
            await removeManagedRequests(reminderID: medication.id)
            return .noFutureOccurrence
        }
        try await reconcile(
            reminderID: medication.id,
            desired: requests,
            pending: pending
        )
        return .scheduled(
            requestCount: requests.count,
            truncated: plan.isTruncated
        )
    }

    func scheduleFollowUpUserInitiated(
        followUp: FollowUp,
        displayName: String? = nil
    ) async throws -> AppleReminderSchedulingResult {
        guard followUp.reminderEnabled, followUp.status == .pending else {
            await removeManagedRequests(reminderID: followUp.id)
            return .disabled
        }
        let authorization = try await userInitiatedAuthorization()
        guard authorization else {
            return .permissionDenied(openSettingsRequired: true)
        }
        let pending = await center.pendingRequests()
        let capacity = availableCapacity(
            replacing: followUp.id,
            pending: pending
        )
        let reference = now()
        let dates = followUpNotificationDates(
            plannedDate: followUp.plannedDate
        )
        .filter { $0 > reference }
        .prefix(capacity)
        let body = String(
            format: Copy.System.notificationFollowUpBodyFormat,
            followUp.items.joined(separator: "、")
        )
        let requests = dates.enumerated().map { index, fireDate in
            LocalNotificationRequest(
                identifier: managedIdentifier(
                    reminderID: followUp.id,
                    occurrenceID: "followup.\(index).\(Int64(fireDate.timeIntervalSince1970))"
                ),
                fireDate: fireDate,
                timezoneIdentifier: calendar.timeZone.identifier,
                title: Copy.System.notificationFollowUpTitle,
                body: body,
                userInfo: [
                    "carethread.kind": ReminderKind.followUp.rawValue,
                    "carethread.patient": followUp.patientId.uuidString,
                    "carethread.followup": followUp.id.uuidString,
                    "carethread.member": displayName ?? ""
                ]
            )
        }
        guard !requests.isEmpty else {
            await removeManagedRequests(reminderID: followUp.id)
            return .noFutureOccurrence
        }
        try await reconcile(
            reminderID: followUp.id,
            desired: requests,
            pending: pending
        )
        return .scheduled(
            requestCount: requests.count,
            truncated: requests.count < followUpNotificationDates(
                plannedDate: followUp.plannedDate
            ).filter { $0 > reference }.count
        )
    }

    func removeManagedRequests(reminderID: UUID) async {
        let prefix = managedReminderPrefix(reminderID)
        let identifiers = await center.pendingRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !identifiers.isEmpty else { return }
        await center.remove(identifiers: identifiers)
        AppLog.data.info("Removed \(identifiers.count) local reminder requests")
    }

    func followUpNotificationDates(plannedDate: Date) -> [Date] {
        let day = calendar.startOfDay(for: plannedDate)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: day)
        let previousMorning = previousDay.flatMap {
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0)
        }
        let sameDayMorning = calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: day
        )
        return [previousMorning, sameDayMorning]
            .compactMap { $0 }
            .sorted()
    }

    private func userInitiatedAuthorization() async throws -> Bool {
        switch await center.authorizationStatus() {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await center.requestAuthorization()
        }
    }

    private func availableCapacity(
        replacing reminderID: UUID,
        pending: [LocalNotificationRequest]
    ) -> Int {
        let replacingPrefix = managedReminderPrefix(reminderID)
        let requestsKept = pending.filter {
            !$0.identifier.hasPrefix(replacingPrefix)
        }.count
        return max(
            0,
            ReminderPlanner.maximumSystemRequestBudget - requestsKept
        )
    }

    private func reconcile(
        reminderID: UUID,
        desired: [LocalNotificationRequest],
        pending: [LocalNotificationRequest]
    ) async throws {
        let prefix = managedReminderPrefix(reminderID)
        let existing = pending.filter { $0.identifier.hasPrefix(prefix) }
        let desiredIDs = Set(desired.map(\.identifier))
        let existingIDs = Set(existing.map(\.identifier))
        let removals = existing.filter { !desiredIDs.contains($0.identifier) }
        let additions = desired.filter { !existingIDs.contains($0.identifier) }

        if !removals.isEmpty {
            await center.remove(identifiers: removals.map(\.identifier))
        }
        var added: [String] = []
        do {
            for request in additions {
                try await center.add(request)
                added.append(request.identifier)
            }
        } catch {
            if !added.isEmpty {
                await center.remove(identifiers: added)
            }
            for request in removals {
                try? await center.add(request)
            }
            AppLog.data.error("Local reminder reconciliation failed")
            throw AppleReminderSchedulerError.systemScheduleFailed
        }
        AppLog.data.info(
            "Reconciled local reminder requests: add \(additions.count), remove \(removals.count)"
        )
    }

    private func managedReminderPrefix(_ reminderID: UUID) -> String {
        "\(Self.managedPrefix)\(reminderID.uuidString.lowercased())."
    }

    private func managedIdentifier(
        reminderID: UUID,
        occurrenceID: String
    ) -> String {
        "\(managedReminderPrefix(reminderID))\(occurrenceID)"
    }
}
