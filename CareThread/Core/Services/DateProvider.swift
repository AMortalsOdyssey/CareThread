import Foundation

protocol DateProvider {
    var now: Date { get }
}

struct SystemDateProvider: DateProvider {
    var now: Date { Date() }
}

struct FixedDateProvider: DateProvider {
    let now: Date
}

enum CTDate {
    static let calendar = Calendar(identifier: .gregorian)

    static func make(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date ?? .distantPast
    }
}

