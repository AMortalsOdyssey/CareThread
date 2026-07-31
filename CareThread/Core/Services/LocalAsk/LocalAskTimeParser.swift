import Foundation

struct LocalAskTimeParser {
    private var calendar: Calendar

    init(timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func parse(
        _ query: String,
        now: Date,
        procedureDates: [Date] = []
    ) -> LocalAskTimeScope {
        let source = LocalAskTokenizer().normalizedQuery(query)
        let thisYear = calendar.component(.year, from: now)

        if source.contains("最近三个月"),
           let start = calendar.date(byAdding: .month, value: -3, to: now) {
            return interval(start: start, end: inclusiveEnd(now), label: "最近三个月")
        }
        if source.contains("上个月"),
           let thisMonth = startOfMonth(now),
           let previousMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) {
            return interval(start: previousMonth, end: thisMonth, label: "上个月")
        }
        if source.contains("去年"),
           let start = startOfYear(thisYear - 1),
           let end = startOfYear(thisYear) {
            return interval(start: start, end: end, label: "去年")
        }
        if source.contains("今年"),
           let start = startOfYear(thisYear) {
            return interval(start: start, end: inclusiveEnd(now), label: "今年")
        }
        if source.contains("三年前"),
           let start = startOfYear(thisYear - 3),
           let end = startOfYear(thisYear - 2) {
            return interval(start: start, end: end, label: "三年前")
        }
        if let explicitYear = explicitYear(in: source),
           let start = startOfYear(explicitYear),
           let end = startOfYear(explicitYear + 1) {
            return interval(start: start, end: end, label: "\(explicitYear)年")
        }
        if source.contains("术后") {
            if let anchor = procedureDates.filter({ $0 <= now }).max() {
                return interval(start: anchor, end: inclusiveEnd(now), label: "术后")
            }
            return fallback()
        }
        if source.contains("最近一次") || source.contains("上次") {
            return LocalAskTimeScope(
                selection: .mostRecent,
                interval: nil,
                displayLabel: "最近一次",
                didFallback: false
            )
        }
        if source.contains("最近去过"), source.contains("医院") {
            return LocalAskTimeScope(
                selection: .allTime,
                interval: nil,
                displayLabel: "全部时间（较新记录优先）",
                didFallback: false
            )
        }
        if source.contains("第一次") {
            return LocalAskTimeScope(
                selection: .earliest,
                interval: nil,
                displayLabel: "第一次",
                didFallback: false
            )
        }
        if containsUnsupportedTemporalCue(source) {
            return fallback()
        }
        return .allTime
    }

    func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func explicitYear(in source: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(20\d{2})年"#),
              let match = regex.firstMatch(
                in: source,
                range: NSRange(source.startIndex..<source.endIndex, in: source)
              ),
              let range = Range(match.range(at: 1), in: source),
              let year = Int(source[range]) else {
            return nil
        }
        return year
    }

    private func startOfYear(_ year: Int) -> Date? {
        calendar.date(from: DateComponents(year: year, month: 1, day: 1))
    }

    private func startOfMonth(_ date: Date) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components)
    }

    private func inclusiveEnd(_ date: Date) -> Date {
        date.addingTimeInterval(0.001)
    }

    private func interval(start: Date, end: Date, label: String) -> LocalAskTimeScope {
        LocalAskTimeScope(
            selection: .interval,
            interval: DateInterval(start: start, end: end),
            displayLabel: label,
            didFallback: false
        )
    }

    private func fallback() -> LocalAskTimeScope {
        LocalAskTimeScope(
            selection: .allTime,
            interval: nil,
            displayLabel: "全部时间",
            didFallback: true
        )
    }

    private func containsUnsupportedTemporalCue(_ source: String) -> Bool {
        ["前一阵子", "前段时间", "很久以前", "大前年", "近期", "最近"].contains {
            source.contains($0)
        }
    }
}
