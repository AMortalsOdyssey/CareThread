import Foundation

struct ComparisonPeriod: Equatable {
    let label: String
    let interval: DateInterval

    init(label: String, start: Date, end: Date) {
        self.label = label
        self.interval = DateInterval(
            start: min(start, end),
            end: max(start, end)
        )
    }

    func contains(_ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }
}

struct ComparisonMetricValue: Equatable {
    let value: Double
    let date: Date
    let recordID: UUID
}

struct MetricComparison: Equatable, Identifiable {
    let normalizedName: String
    let displayName: String
    let unit: String
    let earlier: ComparisonMetricValue
    let later: ComparisonMetricValue

    var id: String { "\(normalizedName)|\(normalizedUnit)" }
    var delta: Double { later.value - earlier.value }
    var normalizedUnit: String {
        LocalComparisonBuilder.normalizedUnit(unit)
    }
}

struct ComparisonFactCounts: Equatable {
    let recordCount: Int
    let abnormalRecordCount: Int
    let symptomCounts: [String: Int]
}

struct LocalComparisonReport: Equatable {
    let memberID: UUID
    let earlierPeriod: ComparisonPeriod
    let laterPeriod: ComparisonPeriod
    let metrics: [MetricComparison]
    let earlierFacts: ComparisonFactCounts
    let laterFacts: ComparisonFactCounts
    let addedTextFacts: [String]
    let removedTextFacts: [String]
    let unavailableMetricNames: [String]
    let insufficientDataMessage: String?
    let disclaimer: String

    var hasAnyFacts: Bool {
        earlierFacts.recordCount > 0 || laterFacts.recordCount > 0
    }
}

enum LocalComparisonBuilder {
    static func build(
        memberID: UUID,
        records: [BriefRecordSnapshot],
        earlierPeriod: ComparisonPeriod,
        laterPeriod: ComparisonPeriod
    ) -> LocalComparisonReport {
        let scoped = records.filter {
            $0.patientID == memberID && $0.reviewStatus == .confirmed
        }
        let earlier = scoped.filter { earlierPeriod.contains($0.eventDate) }
        let later = scoped.filter { laterPeriod.contains($0.eventDate) }
        let earlierMetrics = latestMetrics(in: earlier)
        let laterMetrics = latestMetrics(in: later)
        let sharedKeys = Set(earlierMetrics.keys)
            .intersection(laterMetrics.keys)
            .sorted()
        let comparisons = sharedKeys.compactMap { key -> MetricComparison? in
            guard let first = earlierMetrics[key],
                  let second = laterMetrics[key] else {
                return nil
            }
            return MetricComparison(
                normalizedName: first.normalizedName,
                displayName: second.displayName,
                unit: second.unit,
                earlier: first.value,
                later: second.value
            )
        }
        let unpairedKeys = Set(earlierMetrics.keys)
            .symmetricDifference(Set(laterMetrics.keys))
        let unavailable = unpairedKeys
            .compactMap { earlierMetrics[$0] ?? laterMetrics[$0] }
            .map { "\($0.displayName)（\($0.unit.isEmpty ? "无单位" : $0.unit)）" }
            .sorted()
        let earlierText = textFacts(in: earlier)
        let laterText = textFacts(in: later)
        let message: String?
        if earlier.isEmpty && later.isEmpty {
            message = "两个时段都没有已确认记录，暂时无法对比。"
        } else if earlier.isEmpty {
            message = "前一时段没有已确认记录，只能展示后一时段的事实。"
        } else if later.isEmpty {
            message = "后一时段没有已确认记录，只能展示前一时段的事实。"
        } else if comparisons.isEmpty {
            message = "两个时段没有同名且同单位的数值指标，暂时无法计算指标变化。"
        } else {
            message = nil
        }
        return LocalComparisonReport(
            memberID: memberID,
            earlierPeriod: earlierPeriod,
            laterPeriod: laterPeriod,
            metrics: comparisons,
            earlierFacts: factCounts(in: earlier),
            laterFacts: factCounts(in: later),
            addedTextFacts: Array(laterText.subtracting(earlierText)).sorted(),
            removedTextFacts: Array(earlierText.subtracting(laterText)).sorted(),
            unavailableMetricNames: unavailable,
            insufficientDataMessage: message,
            disclaimer: "这是设备本地的简要事实对比，仅陈述记录和数值变化，不代表病情判断，也不提供诊断或建议。"
        )
    }

    static func normalizedUnit(_ unit: String) -> String {
        unit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(
                of: "\\s+",
                with: "",
                options: .regularExpression
            )
    }

    private struct MetricCandidate {
        let normalizedName: String
        let displayName: String
        let unit: String
        let value: ComparisonMetricValue
    }

    private static func latestMetrics(
        in records: [BriefRecordSnapshot]
    ) -> [String: MetricCandidate] {
        var values: [String: MetricCandidate] = [:]
        for record in records {
            for measurement in record.measurements {
                guard let numericValue = measurement.numericValue,
                      numericValue.isFinite else {
                    continue
                }
                let normalizedName = MemberIdentity.normalize(measurement.name)
                guard !normalizedName.isEmpty else { continue }
                let unitKey = normalizedUnit(measurement.unit)
                let key = "\(normalizedName)|\(unitKey)"
                let candidate = MetricCandidate(
                    normalizedName: normalizedName,
                    displayName: measurement.name,
                    unit: measurement.unit.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    value: ComparisonMetricValue(
                        value: numericValue,
                        date: record.eventDate,
                        recordID: record.id
                    )
                )
                guard let existing = values[key] else {
                    values[key] = candidate
                    continue
                }
                if candidate.value.date > existing.value.date
                    || (
                        candidate.value.date == existing.value.date
                            && candidate.value.recordID.uuidString
                                < existing.value.recordID.uuidString
                    ) {
                    values[key] = candidate
                }
            }
        }
        return values
    }

    private static func factCounts(
        in records: [BriefRecordSnapshot]
    ) -> ComparisonFactCounts {
        var symptoms: [String: Int] = [:]
        for tag in records.flatMap(\.tags) where tag.kind == .symptom {
            let value = tag.value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !value.isEmpty else { continue }
            symptoms[value, default: 0] += 1
        }
        return ComparisonFactCounts(
            recordCount: records.count,
            abnormalRecordCount: records.filter(\.isAbnormal).count,
            symptomCounts: symptoms
        )
    }

    private static func textFacts(
        in records: [BriefRecordSnapshot]
    ) -> Set<String> {
        Set(records.compactMap {
            let value = $0.summary.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return value.isEmpty ? nil : value
        })
    }
}
