import Foundation

enum M4M5DateFormatting {
    static let day: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "M月d日"
        return value
    }()

    static let fullDay: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "yyyy年M月d日"
        return value
    }()

    static let weekday: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "M月d日 EEEE"
        return value
    }()

    static func clock(_ time: ReminderTime) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }
}
extension FrequencyPreset {
    var m4m5DisplayName: String {
        switch self {
        case .dailyOne: Copy.Medication.frequencyDailyOne
        case .dailyTwo: Copy.Medication.frequencyDailyTwo
        case .dailyThree: Copy.Medication.frequencyDailyThree
        case .everyOtherDay: Copy.Medication.frequencyEveryOtherDay
        case .weekly: Copy.Medication.frequencyWeekly
        case .asNeeded: Copy.Medication.frequencyAsNeeded
        }
    }
}

enum M4M5CalendarMath {
    static func startOfDay(
        _ date: Date,
        calendar: Calendar = .current
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func dayDistance(
        from now: Date,
        to date: Date,
        calendar: Calendar = .current
    ) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    static func greeting(
        at date: Date,
        calendar: Calendar = .current
    ) -> String {
        switch calendar.component(.hour, from: date) {
        case 0..<12: Copy.Home.morningGreeting
        case 12..<18: Copy.Home.afternoonGreeting
        default: Copy.Home.eveningGreeting
        }
    }
}
