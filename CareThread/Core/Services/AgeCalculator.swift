import Foundation

struct AgeResult: Equatable {
    var age: Int?
    var hasInvalidChronology: Bool
    var source: AgeSource
}

enum AgeSource: Equatable {
    case manual
    case calculated
    case unavailable
}

enum AgeCalculator {
    static func age(
        birthday: Date?,
        at eventDate: Date,
        manualAge: Int?,
        calendar: Calendar = CTDate.calendar
    ) -> AgeResult {
        if let manualAge {
            guard manualAge >= 0, manualAge <= 130 else {
                AppLog.data.warning("Manual age is outside supported range")
                return AgeResult(age: nil, hasInvalidChronology: true, source: .unavailable)
            }
            return AgeResult(age: manualAge, hasInvalidChronology: false, source: .manual)
        }

        guard let birthday else {
            return AgeResult(age: nil, hasInvalidChronology: false, source: .unavailable)
        }
        guard birthday <= eventDate else {
            AppLog.data.warning("Birthday is later than the event date")
            return AgeResult(age: nil, hasInvalidChronology: true, source: .unavailable)
        }

        let components = calendar.dateComponents([.year], from: birthday, to: eventDate)
        guard let years = components.year, years >= 0 else {
            AppLog.data.error("Age calculation did not produce a valid year component")
            return AgeResult(age: nil, hasInvalidChronology: true, source: .unavailable)
        }
        return AgeResult(age: years, hasInvalidChronology: false, source: .calculated)
    }
}

