import SwiftData
import SwiftUI

struct LocalComparisonView: View {
    @Environment(\.modelContext) private var modelContext
    let patientID: UUID
    var now: () -> Date = Date.init

    @State private var input: BriefInput?
    @State private var earlierStart = CTDate.make(2025, 7, 31)
    @State private var earlierEnd = CTDate.make(2026, 1, 31)
    @State private var laterStart = CTDate.make(2026, 1, 31)
    @State private var laterEnd = CTDate.make(2026, 8, 1)
    @State private var report: LocalComparisonReport?
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s4) {
                M4M5StatusBanner(message: Copy.Brief.comparisonNotice)
                periodCard(
                    title: Copy.Brief.earlierPeriod,
                    start: $earlierStart,
                    end: $earlierEnd,
                    prefix: "m7.compare.earlier"
                )
                periodCard(
                    title: Copy.Brief.laterPeriod,
                    start: $laterStart,
                    end: $laterEnd,
                    prefix: "m7.compare.later"
                )
                M4M5PrimaryButton(
                    title: Copy.Brief.generateComparison,
                    systemImage: "arrow.left.arrow.right",
                    isEnabled: input != nil && !loadFailed,
                    action: compare
                )
                .accessibilityIdentifier("m7.compare.generate")
                if loadFailed {
                    M4M5StatusBanner(
                        message: Copy.Brief.loadingFailed,
                        isDanger: true
                    )
                }
                if let report {
                    comparisonContent(report)
                }
                Text(Copy.Brief.futureCapability)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
            .padding(CT.Space.s5)
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Brief.comparisonTitle)
        .task(id: patientID) {
            configureInitialPeriods()
            load()
        }
        .accessibilityIdentifier("m7.compare")
    }

    private func periodCard(
        title: String,
        start: Binding<Date>,
        end: Binding<Date>,
        prefix: String
    ) -> some View {
        M4M5Card {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                M4M5SectionTitle(text: title)
                DatePicker(
                    "开始",
                    selection: start,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("\(prefix).start")
                DatePicker(
                    "结束（不含当天）",
                    selection: end,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("\(prefix).end")
            }
        }
    }

    private func comparisonContent(
        _ report: LocalComparisonReport
    ) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s4) {
            if let message = report.insufficientDataMessage {
                M4M5StatusBanner(message: message)
                    .accessibilityIdentifier("m7.compare.insufficient")
            }
            if !report.metrics.isEmpty {
                comparisonSection(Copy.Brief.metricComparison) {
                    ForEach(report.metrics) { metric in
                        VStack(alignment: .leading, spacing: CT.Space.s1) {
                            Text("\(metric.displayName)（\(metric.unit.isEmpty ? "无单位" : metric.unit)）")
                                .font(CT.Font.headline)
                            Text(
                                "\(number(metric.earlier.value)) → \(number(metric.later.value))，变化 \(signed(metric.delta))"
                            )
                            .font(CT.Font.valueMono)
                        }
                    }
                }
            }
            comparisonSection(Copy.Brief.factComparison) {
                Text(
                    "记录数：\(report.earlierFacts.recordCount) → \(report.laterFacts.recordCount)"
                )
                Text(
                    "含异常事实的记录：\(report.earlierFacts.abnormalRecordCount) → \(report.laterFacts.abnormalRecordCount)"
                )
                let symptomNames = Set(report.earlierFacts.symptomCounts.keys)
                    .union(report.laterFacts.symptomCounts.keys)
                    .sorted()
                ForEach(symptomNames, id: \.self) { name in
                    Text(
                        "\(name)：\(report.earlierFacts.symptomCounts[name, default: 0]) → \(report.laterFacts.symptomCounts[name, default: 0]) 次记录"
                    )
                }
            }
            if !report.addedTextFacts.isEmpty
                || !report.removedTextFacts.isEmpty {
                comparisonSection(Copy.Brief.textChanges) {
                    ForEach(report.addedTextFacts, id: \.self) {
                        Text("后一时段新增记录文字：\($0)")
                    }
                    ForEach(report.removedTextFacts, id: \.self) {
                        Text("前一时段曾记录、后一时段未出现：\($0)")
                    }
                }
            }
            if !report.unavailableMetricNames.isEmpty {
                M4M5StatusBanner(
                    message:
                        "以下指标因只出现在一个时段，或单位不同，未计算变化："
                        + report.unavailableMetricNames.joined(separator: "、")
                )
            }
            Text(report.disclaimer)
                .font(CT.Font.label)
                .foregroundStyle(CT.Color.inkTertiary)
        }
        .accessibilityIdentifier("m7.compare.result")
    }

    private func comparisonSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        M4M5Card {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                M4M5SectionTitle(text: title)
                content()
                    .font(CT.Font.body)
                    .foregroundStyle(CT.Color.inkPrimary)
            }
        }
    }

    private func configureInitialPeriods() {
        var calendar = CTDate.calendar
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let today = calendar.startOfDay(for: now())
        laterEnd = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today
        laterStart = calendar.date(byAdding: .month, value: -6, to: today)
            ?? today
        earlierEnd = laterStart
        earlierStart = calendar.date(
            byAdding: .month,
            value: -6,
            to: laterStart
        ) ?? laterStart
    }

    @MainActor
    private func load() {
        do {
            input = try M7BriefDataLoader(context: modelContext)
                .load(patientID: patientID)
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.data.error(
                "Comparison load failed: \(error.localizedDescription)"
            )
        }
    }

    private func compare() {
        guard let input else { return }
        report = LocalComparisonBuilder.build(
            memberID: patientID,
            records: input.records,
            earlierPeriod: ComparisonPeriod(
                label: Copy.Brief.earlierPeriod,
                start: earlierStart,
                end: earlierEnd
            ),
            laterPeriod: ComparisonPeriod(
                label: Copy.Brief.laterPeriod,
                start: laterStart,
                end: laterEnd
            )
        )
        AppLog.userAction.info(
            "Local two-period factual comparison generated"
        )
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }

    private func signed(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + number(value)
    }
}
