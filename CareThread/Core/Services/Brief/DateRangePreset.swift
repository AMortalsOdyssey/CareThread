import Foundation

/// User-facing export windows. Boundaries use calendar days instead of fixed
/// second counts so daylight-saving transitions cannot shift a record out of
/// the selected range.
enum DateRangePreset: String, CaseIterable, Identifiable {
    case oneMonth
    case sixMonths
    case oneYear
    case twoYears
    case fiveYears
    case tenYears
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneMonth: "近 1 个月"
        case .sixMonths: "近半年"
        case .oneYear: "近 1 年"
        case .twoYears: "近 2 年"
        case .fiveYears: "近 5 年"
        case .tenYears: "近 10 年"
        case .all: "全部"
        }
    }

    /// Returns a half-open interval `[startOfBoundaryDay, startOfTomorrow)`.
    /// `all` returns nil, which callers interpret as unbounded.
    func interval(
        endingAt date: Date,
        calendar inputCalendar: Calendar = CTDate.calendar
    ) -> DateInterval? {
        guard self != .all else { return nil }
        var calendar = inputCalendar
        if calendar.timeZone.identifier.isEmpty {
            calendar.timeZone = .current
        }
        let today = calendar.startOfDay(for: date)
        guard let upperBound = calendar.date(byAdding: .day, value: 1, to: today),
              let lowerBound = calendar.date(
                byAdding: component,
                value: amount,
                to: today
              ) else {
            return nil
        }
        return DateInterval(start: lowerBound, end: upperBound)
    }

    func contains(
        _ candidate: Date,
        endingAt date: Date,
        calendar: Calendar = CTDate.calendar
    ) -> Bool {
        guard let interval = interval(endingAt: date, calendar: calendar) else {
            return true
        }
        return candidate >= interval.start && candidate < interval.end
    }

    private var component: Calendar.Component {
        switch self {
        case .oneMonth, .sixMonths: .month
        case .oneYear, .twoYears, .fiveYears, .tenYears: .year
        case .all: .day
        }
    }

    private var amount: Int {
        switch self {
        case .oneMonth: -1
        case .sixMonths: -6
        case .oneYear: -1
        case .twoYears: -2
        case .fiveYears: -5
        case .tenYears: -10
        case .all: 0
        }
    }
}
