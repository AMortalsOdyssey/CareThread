import Foundation

struct ExtractionEngine {
    private let calendar: Calendar

    init(calendar: Calendar = CTDate.calendar) {
        self.calendar = calendar
    }

    func extract(
        _ sourceText: String,
        today: Date,
        engineIdentifier: String = "text-fixture"
    ) -> ExtractionResult {
        let text = normalize(sourceText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLog.extraction.warning("Extraction received empty OCR text")
            return .empty
        }

        let typeResult = extractType(text)
        let dateResult = extractDate(text, today: today)
        let hospital = extractHospital(text)
        let department = extractDepartment(text)
        let labs = extractLabItems(text)
        var explicitAbnormals = labs
            .filter { $0.confidence == .high && $0.flag != .none }
            .map { item in
                let marker: String
                switch item.flag {
                case .low: marker = "↓"
                case .high: marker = "↑"
                case .positive: marker = "+"
                case .none: marker = ""
                }
                return "\(item.name) \(format(item.value)) \(marker)".trimmingCharacters(in: .whitespaces)
            }
        let medicationHints = extractMedicationHints(text)
        let followUpHints = extractFollowUpHints(text, eventDate: dateResult.date)
        let fields = extractAdditionalDates(text, chosen: dateResult.date)
        let summary = extractSummary(
            text,
            type: typeResult.type,
            labItems: labs,
            abnormals: explicitAbnormals
        )
        if typeResult.type == .pathology,
           ["癌", "恶性", "转移"].contains(where: summary.contains) {
            explicitAbnormals.append(summary)
        }
        let title = extractTitle(text, type: typeResult.type)

        return ExtractionResult(
            type: typeResult.type,
            typeConfidence: typeResult.confidence,
            eventDate: dateResult.date,
            eventDateConfidence: dateResult.confidence,
            hospital: hospital,
            department: department,
            title: title,
            summary: summary,
            labItems: labs,
            abnormalFlags: explicitAbnormals,
            structuredFields: fields,
            medicationHints: medicationHints,
            followUpHints: followUpHints,
            engineIdentifier: engineIdentifier
        )
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    private func extractDate(_ text: String, today: Date) -> (date: Date?, confidence: Confidence) {
        let contextualLabels = [
            "出院日期", "就诊日期", "检查日期", "报告日期", "采集日期", "送检日期"
        ]
        for label in contextualLabels {
            guard let range = text.range(of: label) else { continue }
            let tail = String(text[range.lowerBound...].prefix(64))
            if let date = firstDate(in: tail) {
                return (date, date > today ? .low : .high)
            }
        }
        if let date = firstDate(in: String(text.prefix(160))) ?? firstDate(in: text) {
            return (date, date > today ? .low : .high)
        }
        return (nil, .low)
    }

    private func firstDate(in text: String) -> Date? {
        let pattern = #"(\d{4})[-年/.](\d{1,2})[-月/.](\d{1,2})日?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let yearRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text),
              let dayRange = Range(match.range(at: 3), in: text),
              let year = Int(text[yearRange]),
              let month = Int(text[monthRange]),
              let day = Int(text[dayRange]) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            AppLog.extraction.warning("Discarded an invalid calendar date")
            return nil
        }
        return date
    }

    private func extractAdditionalDates(_ text: String, chosen: Date?) -> [KeyValueItem] {
        let labels = ["入院日期", "送检日期", "采集日期", "报告日期", "检查日期", "就诊日期", "出院日期"]
        return labels.compactMap { label in
            guard let range = text.range(of: label) else { return nil }
            let tail = String(text[range.lowerBound...].prefix(48))
            guard let date = firstDate(in: tail), date != chosen else { return nil }
            return KeyValueItem(key: label, value: CTDateFormatter.iso.string(from: date))
        }
    }

    private func extractHospital(_ text: String) -> String? {
        let pattern = #"[一-龥]{2,24}(?:妇幼保健院|医学中心|体检中心|卫生院|医院|诊所)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
        .max { $0.count < $1.count }
    }

    private func extractDepartment(_ text: String) -> String? {
        let departments = [
            "超声医学科", "风湿免疫科", "甲状腺外科", "耳鼻喉科", "呼吸内科", "消化内科",
            "泌尿外科", "内分泌科", "乳腺外科", "神经内科", "血液科", "放射科", "影像科",
            "检验科", "超声科", "病理科", "普外科", "心内科", "肾内科", "肿瘤科", "放疗科",
            "感染科", "急诊科", "康复科", "麻醉科", "门诊部", "妇科", "产科", "儿科",
            "皮肤科", "眼科", "口腔科", "骨科", "全科", "中医科"
        ]
        let prioritizedLabels = ["送检科室", "申请科室", "科室"]
        for label in prioritizedLabels {
            guard let range = text.range(of: label) else { continue }
            let tail = String(text[range.lowerBound...].prefix(50))
            if let match = departments.first(where: tail.contains) {
                return match
            }
        }
        return departments.first(where: text.contains)
    }

    private func extractType(_ text: String) -> (type: RecordType, confidence: Confidence) {
        let rules: [(RecordType, [String], [String])] = [
            (.lab, ["参考区间", "参考值", "检验报告"], ["↑", "↓", "mIU/L", "mmol/L", "g/L", "10^9/L"]),
            (.imaging, ["影像学表现", "检查所见", "超声所见", "检查结论", "CT检查报告", "超声检查报告", "MRI", "PET"], ["超声", "B超", "彩超", "平扫", "增强", "印象"]),
            (.pathology, ["病理诊断", "免疫组化", "病理号"], ["送检", "蜡块", "切片"]),
            (.discharge, ["出院小结", "出院记录", "出院医嘱"], ["入院日期", "出院日期"]),
            (.outpatient, ["门诊病历", "主诉", "现病史"], ["查体", "处理意见"]),
            (.prescription, ["处方笺", "Rx", "用法用量"], ["每日1次", "每日2次", "每日3次", "口服"])
        ]

        var scores: [(RecordType, Int)] = rules.map { type, strong, weak in
            var score = strong.reduce(0) { $0 + (text.contains($1) ? 3 : 0) }
            score += weak.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            if type == .lab && text.contains("病理诊断") {
                score = max(0, score - weak.filter(text.contains).count)
            }
            return (type, score)
        }
        scores.sort {
            $0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 > $1.1
        }
        guard let winner = scores.first, winner.1 >= 3 else {
            return (.other, .low)
        }
        if scores.count > 1, scores[1].1 == winner.1 {
            return (.other, .low)
        }
        return (winner.0, .high)
    }

    private func extractLabItems(_ text: String) -> [LabItem] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let valueMatch = firstNumberMatch(in: line),
                  valueMatch.valueRange.lowerBound > line.startIndex,
                  let range = referenceRange(in: line) else {
                return nil
            }

            var name = String(line[..<valueMatch.valueRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            name = name.replacingOccurrences(
                of: #"^\d+[.)、]\s*"#,
                with: "",
                options: .regularExpression
            )
            guard name.count >= 2,
                  !name.contains("电话"),
                  !name.contains("日期"),
                  !name.contains("年龄") else {
                return nil
            }

            let value = valueMatch.value
            let markerTokens = Set(line.split(whereSeparator: \.isWhitespace).map(String.init))
            let explicitFlag: LabFlag?
            if line.contains("↑") || markerTokens.contains("H") || line.contains("偏高") {
                explicitFlag = .high
            } else if line.contains("↓") || markerTokens.contains("L") || line.contains("偏低") {
                explicitFlag = .low
            } else if line.contains("阳性") || line.contains("(+)") {
                explicitFlag = .positive
            } else {
                explicitFlag = nil
            }
            let inferredFlag: LabFlag
            if let explicitFlag {
                inferredFlag = explicitFlag
            } else if value < range.low {
                inferredFlag = .low
            } else if value > range.high {
                inferredFlag = .high
            } else {
                inferredFlag = .none
            }
            let unit = extractUnit(
                from: line,
                after: valueMatch.valueRange.upperBound,
                beforeRange: range.fullRange.lowerBound
            )
            return LabItem(
                name: name,
                value: value,
                unit: unit,
                refLow: range.low,
                refHigh: range.high,
                flag: inferredFlag,
                confidence: explicitFlag == nil && inferredFlag != .none ? .low : .high
            )
        }
    }

    private func firstNumberMatch(in line: String) -> (value: Double, valueRange: Range<String.Index>)? {
        let pattern = #"(?<![A-Za-z])(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range(at: 1), in: line),
                  let value = Double(line[range]) else { continue }
            let prefix = line[..<range.lowerBound]
            if prefix.range(of: #"\d{4}[-年/.]$"#, options: .regularExpression) != nil {
                continue
            }
            return (value, range)
        }
        return nil
    }

    private func referenceRange(
        in line: String
    ) -> (low: Double, high: Double, fullRange: Range<String.Index>)? {
        let pattern = #"(-?\d+(?:\.\d+)?)\s*[-–~]\s*(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard let match = matches.last,
              let fullRange = Range(match.range, in: line),
              let lowRange = Range(match.range(at: 1), in: line),
              let highRange = Range(match.range(at: 2), in: line),
              let low = Double(line[lowRange]),
              let high = Double(line[highRange]) else {
            return nil
        }
        return (low, high, fullRange)
    }

    private func extractUnit(
        from line: String,
        after valueEnd: String.Index,
        beforeRange rangeStart: String.Index
    ) -> String {
        guard valueEnd < rangeStart else { return "" }
        return line[valueEnd..<rangeStart]
            .replacingOccurrences(of: "↑", with: "")
            .replacingOccurrences(of: "↓", with: "")
            .replacingOccurrences(of: #"(?:^|\s)[HL](?:\s|$)"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func extractMedicationHints(_ text: String) -> [MedicationHint] {
        let knownNames = MedicalSynonymLexicon.entries(in: .medication)
            .flatMap(\.allTerms)
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0 < $1
            }
        var highSection = false
        var results: [MedicationHint] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if line.contains("出院医嘱") || line.contains("处理意见") || line.contains("处方") {
                highSection = true
            }
            guard let name = knownNames.first(where: line.contains) ?? patternedDrugName(in: line),
                  let dose = dose(in: line) else {
                continue
            }
            let frequency = frequencyPerDay(in: line)
            let usageTerms = ["口服", "空腹", "晨起", "餐前", "餐后", "睡前", "皮下注射", "静脉"]
                .filter(line.contains)
            results.append(
                MedicationHint(
                    name: name,
                    doseValue: dose.value,
                    doseUnit: dose.unit,
                    frequencyPerDay: frequency,
                    usage: usageTerms,
                    confidence: highSection ? .high : .low
                )
            )
        }
        return results
    }

    private func patternedDrugName(in line: String) -> String? {
        let pattern = #"[一-龥]{2,12}(?:缓释片|分散片|胶囊|颗粒|口服液|注射液|片)"#
        guard let range = line.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(line[range])
    }

    private func dose(in line: String) -> (value: Double, unit: String)? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(µg|ug|mg|g|ml|片|粒|袋|支)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let valueRange = Range(match.range(at: 1), in: line),
              let unitRange = Range(match.range(at: 2), in: line),
              let value = Double(line[valueRange]) else {
            return nil
        }
        return (value, String(line[unitRange]))
    }

    private func frequencyPerDay(in line: String) -> Int? {
        let mappings = [("qd", 1), ("bid", 2), ("tid", 3)]
        for mapping in mappings where line.lowercased().contains(mapping.0) {
            return mapping.1
        }
        let pattern = #"(?:每日|一日|每天)\s*(\d)\s*次"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return line.contains("每早") || line.contains("每晚") ? 1 : nil
        }
        return Int(line[range])
    }

    private func extractFollowUpHints(_ text: String, eventDate: Date?) -> [FollowUpHint] {
        let relativePattern = #"(?:术后)?\s*(\d+)\s*(天|周|个月|月|年)\s*(?:后)?\s*(?:复查|复诊|随访)\s*([^\n。；]*)"#
        let regex = try? NSRegularExpression(pattern: relativePattern)
        var results: [FollowUpHint] = []
        if let regex {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let countRange = Range(match.range(at: 1), in: text),
                      let unitRange = Range(match.range(at: 2), in: text),
                      let tailRange = Range(match.range(at: 3), in: text),
                      let count = Int(text[countRange]) else {
                    continue
                }
                let unit = String(text[unitRange])
                let days: Int
                switch unit {
                case "天": days = count
                case "周": days = count * 7
                case "年": days = count * 365
                default: days = count * 30
                }
                let rawItems = String(text[tailRange])
                    .replacingOccurrences(of: "，门诊随访", with: "")
                    .replacingOccurrences(of: "门诊随访", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let itemParts: [String]
                if let itemSeparator = try? NSRegularExpression(pattern: #"[、,，及]"#) {
                    itemParts = rawItems.components(separatedBy: itemSeparator)
                } else {
                    itemParts = [rawItems]
                }
                let items = itemParts
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.contains("不适") }
                let planned = eventDate.flatMap {
                    calendar.date(byAdding: .day, value: days, to: $0)
                }
                results.append(
                    FollowUpHint(
                        plannedDate: planned,
                        offsetDays: days,
                        items: items,
                        rawText: rawItems,
                        confidence: .high
                    )
                )
            }
        }

        let periodicPattern = #"定期复查([^\n。；]*)"#
        if let range = text.range(of: periodicPattern, options: .regularExpression) {
            let raw = String(text[range])
                .replacingOccurrences(of: "定期复查", with: "")
                .trimmingCharacters(in: .whitespaces)
            results.append(
                FollowUpHint(
                    plannedDate: nil,
                    offsetDays: nil,
                    items: raw.isEmpty ? [] : [raw],
                    rawText: raw,
                    confidence: .low
                )
            )
        }
        return results
    }

    private func extractSummary(
        _ text: String,
        type: RecordType,
        labItems: [LabItem],
        abnormals: [String]
    ) -> String {
        if type == .lab {
            let prefix = "\(labItems.count) 项指标，\(abnormals.count) 项异常"
            return abnormals.isEmpty ? prefix : "\(prefix)：\(abnormals.joined(separator: "、"))"
        }
        let labels = ["病理诊断", "出院诊断", "检查结论", "印象", "诊断意见"]
        for line in text.split(separator: "\n").map(String.init) {
            for label in labels where line.contains(label) {
                let parts = line.components(separatedBy: ":")
                guard parts.count > 1 else { continue }
                let summary = parts.dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
                if !summary.isEmpty {
                    return String(summary.prefix(80))
                }
            }
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        return String(firstLine.prefix(80))
    }

    private func extractTitle(_ text: String, type: RecordType) -> String {
        let labels = ["检查项目", "项目", "标本"]
        for label in labels {
            let pattern = "\(label)\\s*:\\s*([^\\n]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            var title = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let separator = title.firstIndex(where: { $0 == " " || $0 == "（" }) {
                title = String(title[..<separator])
            }
            if !title.isEmpty {
                return title
            }
        }
        return type.displayName
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}

extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..., in: self)
        let mutable = NSMutableString(string: self)
        regex.replaceMatches(in: mutable, range: range, withTemplate: "\u{001F}")
        return (mutable as String).components(separatedBy: "\u{001F}")
    }
}

enum CTDateFormatter {
    static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = CTDate.calendar
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
