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

    static let dateAndTime: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "yyyy年M月d日 HH:mm"
        return value
    }()

    static func clock(_ time: ReminderTime) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }
}

enum MedicationUsageText {
    static func humanReadable(_ values: [String]) -> String {
        let normalized = values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if normalized == ["晨起", "空腹", "口服"]
            || Set(normalized) == Set(["晨起", "空腹", "口服"]) {
            return "早上空腹吃"
        }
        return normalized
            .map {
                switch $0 {
                case "晨起": "早上"
                case "空腹": "空腹"
                case "口服": "吃"
                default: $0
                }
            }
            .joined(separator: "，")
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
