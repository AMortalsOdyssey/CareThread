import Foundation

enum ReminderPlannerError: Error, Equatable {
    case invalidTimezone
    case invalidDate
    case invalidWindow
    case windowTooLarge(maximumDays: Int)
    case invalidSystemLimit
    case invalidWeeklyCount
    case unexpectedWeeklyCount
    case invalidReminderTime
    case missingReminderTimes
    case reminderTimeCount(expected: Int, actual: Int)
    case asNeededCannotAutoSchedule
}

struct ReminderPlanningInput: Equatable {
    var reminderId: UUID
    var businessRevision: Int
    var frequency: FrequencyPreset
    var weeklyCount: Int?
    var reminderTimes: [ReminderTime]
    var startDate: Date
    var endDate: Date?
    var timezoneIdentifier: String
    var windowStart: Date
    var windowEnd: Date
    /// Slots available to this rolling plan after the caller reserves capacity
    /// for unrelated system notifications.
    var systemRequestLimit: Int

    init(
        reminderId: UUID,
        businessRevision: Int,
        frequency: FrequencyPreset,
        weeklyCount: Int? = nil,
        reminderTimes: [ReminderTime],
        startDate: Date,
        endDate: Date? = nil,
        timezoneIdentifier: String,
        windowStart: Date,
        windowEnd: Date,
        systemRequestLimit: Int
    ) {
        self.reminderId = reminderId
        self.businessRevision = businessRevision
        self.frequency = frequency
        self.weeklyCount = weeklyCount
        self.reminderTimes = reminderTimes
        self.startDate = startDate
        self.endDate = endDate
        self.timezoneIdentifier = timezoneIdentifier
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.systemRequestLimit = systemRequestLimit
    }
}

/// Semantic cadence data only. Presentation layers own all localized copy.
enum ReminderCadenceDescriptor: Codable, Hashable {
    case daily(timesPerDay: Int, times: [ReminderTime])
    case everyOtherDay(times: [ReminderTime])
    case weekly(
        timesPerWeek: Int,
        anchorDate: Date,
        times: [ReminderTime]
    )
    case asNeeded
}

struct ReminderRequestDTO: Codable, Hashable, Identifiable {
    var id: String
    var reminderId: UUID
    var businessRevision: Int
    var fireDate: Date
    var timezoneIdentifier: String
}

struct ReminderRequestPlan: Equatable {
    var requests: [ReminderRequestDTO]
    var cadence: ReminderCadenceDescriptor
    var isAsNeeded: Bool
    var isTruncated: Bool
}

struct ReminderReconciliationPlan: Equatable {
    var schedule: [ReminderRequestDTO]
    var removeIdentifiers: [String]
    var unchangedIdentifiers: [String]
}

enum ReminderAuthorizationStatus: String, Codable {
    case notDetermined
    case denied
    case authorized
}

/// Deliberately has no permission-request API. UI/application orchestration
/// may inspect status and decide whether to show a user-initiated prompt.
protocol ReminderPermissionAdapting {
    func authorizationStatus(
        for destination: ReminderDestination
    ) async -> ReminderAuthorizationStatus
}

enum ReminderPlanner {
    static let maximumSystemRequestBudget = 64
    static let maximumRollingWindowDays = 366

    static func suggestedTimes(
        for frequency: FrequencyPreset
    ) -> [ReminderTime] {
        switch frequency {
        case .dailyOne, .everyOtherDay, .weekly:
            [ReminderTime(hour: 8, minute: 0)]
        case .dailyTwo:
            [
                ReminderTime(hour: 8, minute: 0),
                ReminderTime(hour: 20, minute: 0)
            ]
        case .dailyThree:
            [
                ReminderTime(hour: 8, minute: 0),
                ReminderTime(hour: 13, minute: 0),
                ReminderTime(hour: 20, minute: 0)
            ]
        case .asNeeded:
            []
        }
    }

    static func plan(
        _ input: ReminderPlanningInput
    ) throws -> ReminderRequestPlan {
        guard let timezone = TimeZone(identifier: input.timezoneIdentifier) else {
            throw ReminderPlannerError.invalidTimezone
        }
        guard DomainFieldPolicy.isFinite(input.startDate),
              DomainFieldPolicy.isFinite(input.windowStart),
              DomainFieldPolicy.isFinite(input.windowEnd),
              input.endDate.map(DomainFieldPolicy.isFinite) ?? true else {
            throw ReminderPlannerError.invalidDate
        }
        guard input.windowEnd >= input.windowStart,
              input.endDate.map({ $0 >= input.startDate }) ?? true else {
            throw ReminderPlannerError.invalidWindow
        }
        guard (0...maximumSystemRequestBudget).contains(
            input.systemRequestLimit
        ) else {
            throw ReminderPlannerError.invalidSystemLimit
        }
        do {
            try FrequencySchedulePolicy.validate(
                frequency: input.frequency,
                weeklyCount: input.weeklyCount,
                reminderEnabled: input.frequency != .asNeeded,
                reminderTimes: input.reminderTimes
            )
        } catch let error as FrequencySchedulePolicyError {
            throw mapScheduleError(error)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timezone
        let rollingDays = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: input.windowStart),
            to: calendar.startOfDay(for: input.windowEnd)
        ).day
        guard let rollingDays,
              rollingDays >= 0,
              rollingDays + 1 <= maximumRollingWindowDays else {
            throw ReminderPlannerError.windowTooLarge(
                maximumDays: maximumRollingWindowDays
            )
        }
        let cadence = cadenceDescriptor(for: input)
        if input.frequency == .asNeeded {
            return ReminderRequestPlan(
                requests: [],
                cadence: cadence,
                isAsNeeded: true,
                isTruncated: false
            )
        }
        let lowerBound = max(input.startDate, input.windowStart)
        let upperBound = min(
            input.endDate ?? input.windowEnd,
            input.windowEnd
        )
        guard upperBound >= lowerBound, input.systemRequestLimit > 0 else {
            return ReminderRequestPlan(
                requests: [],
                cadence: cadence,
                isAsNeeded: false,
                isTruncated: input.systemRequestLimit == 0
            )
        }

        let anchorDay = calendar.startOfDay(for: input.startDate)
        var day = calendar.startOfDay(for: lowerBound)
        var candidates: [ReminderRequestDTO] = []
        let candidateCap = input.systemRequestLimit + 1
        var visitedDays = 0
        while day <= upperBound,
              candidates.count < candidateCap,
              visitedDays < maximumRollingWindowDays {
            visitedDays += 1
            if isScheduledDay(
                day,
                anchorDay: anchorDay,
                input: input,
                calendar: calendar
            ) {
                for time in input.reminderTimes.sorted(by: reminderTimeOrder) {
                    guard let fireDate = localDate(
                        on: day,
                        time: time,
                        calendar: calendar
                    ) else { continue }
                    guard fireDate >= lowerBound, fireDate <= upperBound else {
                        continue
                    }
                    candidates.append(
                        ReminderRequestDTO(
                            id: requestIdentifier(
                                reminderId: input.reminderId,
                                businessRevision: input.businessRevision,
                                fireDate: fireDate
                            ),
                            reminderId: input.reminderId,
                            businessRevision: input.businessRevision,
                            fireDate: fireDate,
                            timezoneIdentifier: input.timezoneIdentifier
                        )
                    )
                    if candidates.count >= candidateCap { break }
                }
            }
            guard let next = calendar.date(
                byAdding: .day,
                value: 1,
                to: day
            ) else { break }
            day = next
        }
        candidates.sort {
            ($0.fireDate, $0.id) < ($1.fireDate, $1.id)
        }
        let isTruncated = candidates.count > input.systemRequestLimit
        return ReminderRequestPlan(
            requests: Array(candidates.prefix(input.systemRequestLimit)),
            cadence: cadence,
            isAsNeeded: false,
            isTruncated: isTruncated
        )
    }

    /// Pure set reconciliation. Calling it again with the identifiers produced
    /// by the first result yields no schedules or removals.
    static func reconcile(
        desired plan: ReminderRequestPlan,
        existingIdentifiers: Set<String>
    ) -> ReminderReconciliationPlan {
        let desiredByID = Dictionary(
            uniqueKeysWithValues: plan.requests.map { ($0.id, $0) }
        )
        let desiredIDs = Set(desiredByID.keys)
        return ReminderReconciliationPlan(
            schedule: desiredIDs
                .subtracting(existingIdentifiers)
                .compactMap { desiredByID[$0] }
                .sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) },
            removeIdentifiers: existingIdentifiers
                .subtracting(desiredIDs)
                .sorted(),
            unchangedIdentifiers: desiredIDs
                .intersection(existingIdentifiers)
                .sorted()
        )
    }

    private static func isScheduledDay(
        _ day: Date,
        anchorDay: Date,
        input: ReminderPlanningInput,
        calendar: Calendar
    ) -> Bool {
        let days = calendar.dateComponents(
            [.day],
            from: anchorDay,
            to: day
        ).day ?? 0
        guard days >= 0 else { return false }
        switch input.frequency {
        case .dailyOne, .dailyTwo, .dailyThree:
            return true
        case .everyOtherDay:
            return days.isMultiple(of: 2)
        case .weekly:
            let count = input.weeklyCount ?? 0
            let offsets = Set(
                (0..<count).map { index in
                    Int(floor(Double(index * 7) / Double(count)))
                }
            )
            return offsets.contains(days % 7)
        case .asNeeded:
            return false
        }
    }

    private static func localDate(
        on day: Date,
        time: ReminderTime,
        calendar: Calendar
    ) -> Date? {
        let start = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard let candidate = calendar.nextDate(
            after: start.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return nil
        }
        guard nextDay.map({ candidate < $0 }) ?? true else {
            return nil
        }
        return candidate
    }

    private static func cadenceDescriptor(
        for input: ReminderPlanningInput
    ) -> ReminderCadenceDescriptor {
        let times = input.reminderTimes
            .sorted(by: reminderTimeOrder)
        switch input.frequency {
        case .dailyOne:
            return .daily(timesPerDay: 1, times: times)
        case .dailyTwo:
            return .daily(timesPerDay: 2, times: times)
        case .dailyThree:
            return .daily(timesPerDay: 3, times: times)
        case .everyOtherDay:
            return .everyOtherDay(times: times)
        case .weekly:
            return .weekly(
                timesPerWeek: input.weeklyCount ?? 0,
                anchorDate: input.startDate,
                times: times
            )
        case .asNeeded:
            return .asNeeded
        }
    }

    private static func requestIdentifier(
        reminderId: UUID,
        businessRevision: Int,
        fireDate: Date
    ) -> String {
        let milliseconds = Int64(
            (fireDate.timeIntervalSince1970 * 1_000).rounded()
        )
        return "\(reminderId.uuidString.lowercased()).r\(businessRevision).\(milliseconds)"
    }

    private static func reminderTimeOrder(
        _ lhs: ReminderTime,
        _ rhs: ReminderTime
    ) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    private static func mapScheduleError(
        _ error: FrequencySchedulePolicyError
    ) -> ReminderPlannerError {
        switch error {
        case .invalidWeeklyCount:
            .invalidWeeklyCount
        case .unexpectedWeeklyCount:
            .unexpectedWeeklyCount
        case .invalidReminderTime, .duplicateReminderTime:
            .invalidReminderTime
        case let .reminderTimeCount(expected, actual):
            .reminderTimeCount(expected: expected, actual: actual)
        case .asNeededCannotAutoSchedule:
            .asNeededCannotAutoSchedule
        }
    }
}
