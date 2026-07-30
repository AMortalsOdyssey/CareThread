import EventKit
import Foundation

struct CalendarEventDraft: Equatable {
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var notes: String?
    var alarmOffsets: [TimeInterval]
}

protocol CalendarEventStoreAdapting {
    func authorizationStatus() -> ReminderAuthorizationStatus
    func requestAccess() async throws -> Bool
    func save(_ draft: CalendarEventDraft) throws -> String
}

final class SystemCalendarEventStore: CalendarEventStoreAdapting {
    private let store = EKEventStore()

    func authorizationStatus() -> ReminderAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly, .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func save(_ draft: CalendarEventDraft) throws -> String {
        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.isAllDay = draft.isAllDay
        event.notes = draft.notes
        event.alarms = draft.alarmOffsets.map {
            EKAlarm(relativeOffset: $0)
        }
        try store.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else {
            throw CalendarExportServiceError.missingEventIdentifier
        }
        return identifier
    }
}

enum CalendarExportResult: Equatable {
    case added(eventIdentifier: String)
    case permissionDenied(openSettingsRequired: Bool)
}

enum CalendarExportServiceError: Error, Equatable {
    case invalidDateRange
    case missingEventIdentifier
    case systemSaveFailed
}

/// Writing to Calendar is an explicit export. It does not mutate the business
/// reminder or request access during app launch.
struct CalendarExportService {
    let store: any CalendarEventStoreAdapting
    var calendar: Calendar = .current

    init(
        store: any CalendarEventStoreAdapting = SystemCalendarEventStore(),
        calendar: Calendar = .current
    ) {
        self.store = store
        self.calendar = calendar
    }

    func addFollowUpUserInitiated(
        _ followUp: FollowUp,
        memberName: String
    ) async throws -> CalendarExportResult {
        let allowed: Bool
        switch store.authorizationStatus() {
        case .authorized:
            allowed = true
        case .denied:
            allowed = false
        case .notDetermined:
            allowed = try await store.requestAccess()
        }
        guard allowed else {
            return .permissionDenied(openSettingsRequired: true)
        }

        let start = calendar.startOfDay(for: followUp.plannedDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              end > start else {
            throw CalendarExportServiceError.invalidDateRange
        }
        let draft = CalendarEventDraft(
            title: Copy.System.calendarFollowUpPrefix +
                followUp.items.joined(separator: "、"),
            startDate: start,
            endDate: end,
            isAllDay: true,
            notes: "\(memberName)\n\(Copy.System.calendarNotes)",
            alarmOffsets: [
                TimeInterval(-86_400 + 9 * 3_600),
                TimeInterval(8 * 3_600)
            ]
        )
        do {
            let identifier = try store.save(draft)
            AppLog.data.info("Exported one follow-up to system Calendar")
            return .added(eventIdentifier: identifier)
        } catch let error as CalendarExportServiceError {
            throw error
        } catch {
            AppLog.data.error("System Calendar export failed")
            throw CalendarExportServiceError.systemSaveFailed
        }
    }
}
