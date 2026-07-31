import Charts
import SwiftData
import SwiftUI

enum LocalAskPreset: String, CaseIterable, Identifiable {
    case currentMedication
    case nextFollowUp
    case latestResult
    case recentHospitals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentMedication: "我在吃什么药？"
        case .nextFollowUp: "下次什么时候复查？"
        case .latestResult: "上次检查结果怎么样？"
        case .recentHospitals: "最近去过哪些医院？"
        }
    }

    var systemImage: String {
        switch self {
        case .currentMedication: "pills.fill"
        case .nextFollowUp: "calendar.badge.clock"
        case .latestResult: "chart.xyaxis.line"
        case .recentHospitals: "cross.case.fill"
        }
    }
}

enum LocalAskPresentationPolicy {
    static func showsFreeText(in mode: DisplayMode) -> Bool {
        mode == .standard
    }

    static func presets(in mode: DisplayMode) -> [LocalAskPreset] {
        LocalAskPreset.allCases
    }
}

enum LocalAskGeneratedCopy {
    static let loading = "正在读取这位家人的本地资料…"
    static let loadFailed = "本地资料暂时无法读取"
    static let empty = "没有找到匹配的本地资料"
    static let standardInitialTitle = "只查找本机里的原始记录"
    static let elderInitialTitle = "点一个问题就能查看"
    static let standardInitialBody = "结果只列事实，并提供来源记录入口。不会联网，也不会生成诊断或处置意见。"
    static let elderInitialBody = "不会联网，也不会做医学判断。"
    static let pendingFollowUp = "原记录状态：待复查"
    static let completedFollowUp = "原记录状态：已完成"
    static let matchedSources = "命中的来源记录"
    static let viewSource = "查看来源记录"
    static let viewMedication = "查看本地用药记录"
    static let viewFollowUp = "查看本地复查记录"
    static let missingMetricValue = "原记录未填写数值"

    static let fixedUIStrings = [
        loading,
        loadFailed,
        empty,
        standardInitialTitle,
        elderInitialTitle,
        standardInitialBody,
        elderInitialBody,
        pendingFollowUp,
        completedFollowUp,
        matchedSources,
        viewSource,
        viewMedication,
        viewFollowUp,
        missingMetricValue,
        "原记录标记：偏低",
        "原记录标记：偏高",
        "原记录标记：阳性",
        "今天",
        "已完成"
    ]
}

struct LocalAskRefreshResult {
    var preparedData: LocalAskPreparedData
    var response: LocalAskResponse?
}

struct LocalAskRefreshCoordinator: Equatable {
    private(set) var sourceRevision = 0

    mutating func sourceDidSave() {
        sourceRevision &+= 1
    }

    @MainActor
    func rebuild(
        service: LocalAskQueryService = LocalAskQueryService(),
        memberID: UUID,
        activeQuery: String?,
        records: [MedicalRecord],
        medications: [Medication],
        followUps: [FollowUp],
        now: Date = Date()
    ) async throws -> LocalAskRefreshResult {
        let preparedData = try await service.prepareAsync(
            memberID: memberID,
            records: records,
            medications: medications,
            followUps: followUps
        )
        try Task.checkCancellation()
        let response = activeQuery.map {
            service.ask($0, in: preparedData, now: now)
        }
        return LocalAskRefreshResult(
            preparedData: preparedData,
            response: response
        )
    }
}

private struct LocalAskPreparationID: Hashable {
    var patientID: UUID
    var sourceRevision: Int
}

enum LocalAskFactPresentation {
    static func abnormalLabel(_ state: LabFlag) -> String? {
        switch state {
        case .none: nil
        case .low: "↓ 原记录标记：偏低"
        case .high: "↑ 原记录标记：偏高"
        case .positive: "● 原记录标记：阳性"
        }
    }

    static func followUpCountdown(
        plannedDate: Date,
        status: FollowUpStatus,
        now: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> String {
        guard status == .pending else { return "已完成" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: plannedDate)
        let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        switch days {
        case 0: return "今天"
        case 1...: return "还有 \(days) 天"
        default: return "已过期 \(-days) 天"
        }
    }
}

struct LocalAskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var records: [MedicalRecord]
    @Query private var medications: [Medication]
    @Query private var followUps: [FollowUp]

    let patientID: UUID
    let mode: DisplayMode

    @State private var query = ""
    @State private var preparedData: LocalAskPreparedData?
    @State private var response: LocalAskResponse?
    @State private var isPreparing = true
    @State private var loadFailed = false
    @State private var refreshCoordinator = LocalAskRefreshCoordinator()

    init(patientID: UUID, mode: DisplayMode) {
        self.patientID = patientID
        self.mode = mode
        _records = Query(
            filter: #Predicate<MedicalRecord> { $0.patientId == patientID },
            sort: [SortDescriptor(\.eventDate, order: .reverse)]
        )
        _medications = Query(
            filter: #Predicate<Medication> { $0.patientId == patientID },
            sort: [SortDescriptor(\.startDate, order: .reverse)]
        )
        _followUps = Query(
            filter: #Predicate<FollowUp> { $0.patientId == patientID },
            sort: [SortDescriptor(\.plannedDate)]
        )
    }

    var body: some View {
        VStack(spacing: CT.Space.s1) {
            disclaimer
            ScrollView {
                VStack(alignment: .leading, spacing: contentSpacing) {
                    questionControls
                    content
                }
                .padding(screenPadding)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(CT.Color.bgBase)
        .navigationTitle("问我的资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(Copy.Common.done) {
                    dismiss()
                }
                .accessibilityIdentifier("localAsk.done")
            }
        }
        .task(id: LocalAskPreparationID(
            patientID: patientID,
            sourceRevision: refreshCoordinator.sourceRevision
        )) {
            await prepare()
        }
        .dynamicTypeSize(mode == .elder ? ...ElderDynamicTypePolicy.maximum : ...DynamicTypeSize.accessibility5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localAsk.screen")
    }

    private var disclaimer: some View {
        HStack(alignment: .firstTextBaseline, spacing: CT.Space.s2) {
            Image(systemName: "shield.lefthalf.filled")
                .accessibilityHidden(true)
            Text(LocalAskResponse.factualDisclaimer)
        }
        .font(mode == .elder ? CT.Font.elderFootnote : CT.Font.footnote)
        .foregroundStyle(CT.Color.primaryOnContainer)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, screenPadding)
        .padding(.vertical, CT.Space.s3)
        .background(CT.Color.primaryContainer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalAskResponse.factualDisclaimer)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("localAsk.disclaimer")
    }

    @ViewBuilder
    private var questionControls: some View {
        if LocalAskPresentationPolicy.showsFreeText(in: mode) {
            standardQuestionControls
        } else {
            elderQuestionControls
        }
    }

    private var standardQuestionControls: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            Text("想从资料里找什么？")
                .font(CT.Font.title2)
                .foregroundStyle(CT.Color.inkPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: CT.Space.s2) {
                TextField("例如：去年 TSH 的记录", text: $query, axis: .vertical)
                    .font(CT.Font.body)
                    .foregroundStyle(CT.Color.inkPrimary)
                    .lineLimit(1...3)
                    .submitLabel(.search)
                    .onSubmit(runTypedQuery)
                    .accessibilityIdentifier("localAsk.input")
                Button(action: runTypedQuery) {
                    Image(systemName: "magnifyingglass")
                        .font(CT.Font.headline)
                        .frame(
                            minWidth: CT.Size.secondaryButtonHeight,
                            minHeight: CT.Size.secondaryButtonHeight
                        )
                }
                .disabled(
                    LocalAskTokenizer().normalizedQuery(query).isEmpty
                        || preparedData == nil
                )
                .accessibilityLabel("查找")
                .accessibilityIdentifier("localAsk.submit")
            }
            .padding(.leading, CT.Space.s3)
            .background(CT.Color.bgElevated)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.input,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: CT.Radius.input,
                    style: .continuous
                )
                .stroke(CT.Color.outline, lineWidth: CT.Stroke.hairline)
            }

            ScrollView(.horizontal) {
                HStack(spacing: CT.Space.s2) {
                    ForEach(LocalAskPresentationPolicy.presets(in: mode)) { preset in
                        Button(preset.title) {
                            run(preset)
                        }
                        .font(CT.Font.subhead.weight(.semibold))
                        .foregroundStyle(CT.Color.primaryOnContainer)
                        .padding(.horizontal, CT.Space.s3)
                        .frame(minHeight: CT.Size.secondaryButtonHeight)
                        .background(CT.Color.primaryContainer)
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                        .disabled(preparedData == nil)
                        .accessibilityIdentifier("localAsk.chip.\(preset.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("localAsk.presets")
        }
    }

    private var elderQuestionControls: some View {
        VStack(alignment: .leading, spacing: CT.Space.s4) {
            Text("想看哪一项？")
                .font(CT.Font.elderTitle2)
                .foregroundStyle(CT.Color.inkPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(LocalAskPresentationPolicy.presets(in: mode)) { preset in
                ElderBigChoiceButton(
                    title: preset.title,
                    systemImage: preset.systemImage
                ) {
                    run(preset)
                }
                .disabled(preparedData == nil)
                .accessibilityLabel(preset.title)
                .accessibilityIdentifier("localAsk.elder.\(preset.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isPreparing {
            ProgressView(LocalAskGeneratedCopy.loading)
                .font(bodyFont)
                .frame(maxWidth: .infinity, minHeight: CT.Size.recordCardMinHeight)
                .accessibilityIdentifier("localAsk.loading")
        } else if loadFailed {
            ContentUnavailableView(
                LocalAskGeneratedCopy.loadFailed,
                systemImage: "exclamationmark.triangle"
            )
            .accessibilityIdentifier("localAsk.loadFailed")
        } else if let response {
            responseContent(response)
        } else {
            LocalAskFactCard(
                title: mode == .elder
                    ? LocalAskGeneratedCopy.elderInitialTitle
                    : LocalAskGeneratedCopy.standardInitialTitle,
                systemImage: "doc.text.magnifyingglass",
                mode: mode,
                overview: nil,
                accessibilityIdentifier: "localAsk.initial"
            ) {
                Text(
                    mode == .elder
                        ? LocalAskGeneratedCopy.elderInitialBody
                        : LocalAskGeneratedCopy.standardInitialBody
                )
                .font(bodyFont)
                .foregroundStyle(CT.Color.inkSecondary)
            }
        }
    }

    private func responseContent(_ value: LocalAskResponse) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Text(value.scopeNotice)
                .font(mode == .elder ? CT.Font.elderSubhead : CT.Font.subhead)
                .foregroundStyle(CT.Color.inkSecondary)
                .accessibilityIdentifier("localAsk.scope")

            LocalAskOverviewSlot(text: value.factualOverview, mode: mode)

            if value.metricFacts.isEmpty,
               value.medicationFacts.isEmpty,
               value.followUpFacts.isEmpty,
               value.hospitalFacts.isEmpty,
               value.recordHits.isEmpty {
                ContentUnavailableView(
                    LocalAskGeneratedCopy.empty,
                    systemImage: "doc.text.magnifyingglass"
                )
                .accessibilityIdentifier("localAsk.empty")
            } else {
                metricCards(value.metricFacts)
                medicationCards(value.medicationFacts)
                followUpCard(value.followUpFacts)
                hospitalCard(value.hospitalFacts)
                recordCards(value.recordHits)
            }
        }
        .accessibilityIdentifier("localAsk.results")
    }

    @ViewBuilder
    private func hospitalCard(_ facts: [LocalAskHospitalFact]) -> some View {
        if !facts.isEmpty {
            LocalAskFactCard(
                title: "医院记录 · \(facts.count) 家",
                systemImage: "cross.case.fill",
                mode: mode,
                overview: nil,
                accessibilityIdentifier: "localAsk.hospitals"
            ) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        Text(fact.name)
                            .font(valueFont)
                            .foregroundStyle(CT.Color.inkPrimary)
                        Text("最近记录：\(Self.dayFormatter.string(from: fact.latestVisitAt))")
                            .font(bodyFont)
                            .foregroundStyle(CT.Color.inkPrimary)
                        Text("本地资料中有 \(fact.visitCount) 条该机构记录")
                            .font(detailFont)
                            .foregroundStyle(CT.Color.inkSecondary)
                        sourceLink(recordID: fact.sourceRecordID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metricCards(_ facts: [LocalAskMetricFact]) -> some View {
        ForEach(metricGroups(facts), id: \.name) { group in
            LocalAskFactCard(
                title: "\(group.name) · \(group.facts.count) 条记录",
                systemImage: "testtube.2",
                mode: mode,
                overview: nil,
                accessibilityIdentifier: "localAsk.metric.\(group.name)"
            ) {
                ForEach(group.facts) { fact in
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        HStack(alignment: .firstTextBaseline, spacing: CT.Space.s2) {
                            Text(Self.dayFormatter.string(from: fact.recordedAt))
                                .font(detailFont)
                                .foregroundStyle(CT.Color.inkSecondary)
                            Spacer()
                            Text(metricValue(fact))
                                .font(valueFont)
                                .foregroundStyle(CT.Color.inkPrimary)
                        }
                        if let reference = metricReference(fact) {
                            Text("原记录参考范围：\(reference)")
                                .font(detailFont)
                                .foregroundStyle(CT.Color.inkSecondary)
                        }
                        if let abnormal = LocalAskFactPresentation.abnormalLabel(
                            fact.abnormalState
                        ) {
                            Text(abnormal)
                                .font(detailFont)
                                .foregroundStyle(CT.Color.warning)
                        }
                        sourceLink(recordID: fact.sourceRecordID)
                    }
                }
                LocalAskMetricTrend(facts: group.facts, mode: mode)
            }
        }
    }

    @ViewBuilder
    private func medicationCards(_ facts: [LocalAskMedicationFact]) -> some View {
        ForEach(medicationGroups(facts), id: \.name) { group in
            LocalAskFactCard(
                title: group.name,
                systemImage: "pills.fill",
                mode: mode,
                overview: nil,
                accessibilityIdentifier: "localAsk.medication.\(group.name)"
            ) {
                ForEach(group.facts) { fact in
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        Text(medicationDateLine(fact))
                            .font(bodyFont)
                            .foregroundStyle(CT.Color.inkPrimary)
                        Text(medicationDoseLine(fact))
                            .font(detailFont)
                            .foregroundStyle(CT.Color.inkSecondary)
                        medicationSourceLink(fact)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func followUpCard(_ facts: [LocalAskFollowUpFact]) -> some View {
        if !facts.isEmpty {
            LocalAskFactCard(
                title: "复查记录 · \(facts.count) 项",
                systemImage: "calendar.badge.clock",
                mode: mode,
                overview: nil,
                accessibilityIdentifier: "localAsk.followUps"
            ) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        Text(Self.dayFormatter.string(from: fact.plannedDate))
                            .font(valueFont)
                            .foregroundStyle(CT.Color.inkPrimary)
                        Text(fact.items.joined(separator: "、"))
                            .font(bodyFont)
                            .foregroundStyle(CT.Color.inkPrimary)
                        Text(
                            fact.status == .pending
                                ? LocalAskGeneratedCopy.pendingFollowUp
                                : LocalAskGeneratedCopy.completedFollowUp
                        )
                            .font(detailFont)
                            .foregroundStyle(CT.Color.inkSecondary)
                        Text(
                            LocalAskFactPresentation.followUpCountdown(
                                plannedDate: fact.plannedDate,
                                status: fact.status
                            )
                        )
                        .font(detailFont)
                        .foregroundStyle(CT.Color.inkSecondary)
                        followUpSourceLink(fact)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recordCards(_ hits: [LocalAskRecordHit]) -> some View {
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Text(LocalAskGeneratedCopy.matchedSources)
                    .font(mode == .elder ? CT.Font.elderTitle2 : CT.Font.title3)
                    .foregroundStyle(CT.Color.inkPrimary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(hits) { hit in
                    LocalAskFactCard(
                        title: hit.title,
                        systemImage: "doc.text",
                        mode: mode,
                        overview: nil,
                        accessibilityIdentifier: "localAsk.record.\(hit.recordID.uuidString)"
                    ) {
                        Text(Self.dayFormatter.string(from: hit.eventDate))
                            .font(detailFont)
                            .foregroundStyle(CT.Color.inkSecondary)
                        if !hit.summary.isEmpty {
                            Text(hit.summary)
                                .font(bodyFont)
                                .foregroundStyle(CT.Color.inkPrimary)
                                .lineLimit(mode == .elder ? 4 : 3)
                        }
                        if let hospital = records.first(
                            where: { $0.id == hit.recordID }
                        )?.hospital {
                            Text("医院：\(hospital)")
                                .font(detailFont)
                                .foregroundStyle(CT.Color.inkSecondary)
                        }
                        if !hit.matchedTerms.isEmpty {
                            Text("命中：\(hit.matchedTerms.joined(separator: "、"))")
                                .font(detailFont)
                                .foregroundStyle(CT.Color.inkSecondary)
                        }
                        sourceLink(recordID: hit.recordID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sourceLink(recordID: UUID) -> some View {
        if let record = records.first(where: { $0.id == recordID }) {
            NavigationLink {
                RecordDetailView(record: record) {
                    Task { await prepare() }
                }
            } label: {
                Label(
                    LocalAskGeneratedCopy.viewSource,
                    systemImage: "arrow.right.circle"
                )
                    .font(mode == .elder ? CT.Font.elderSubhead : CT.Font.subhead)
                    .frame(minHeight: mode == .elder
                        ? CT.Size.elderTouchTarget
                        : CT.Size.secondaryButtonHeight)
                    .accessibilityIdentifier(
                        "localAsk.source.\(recordID.uuidString)"
                    )
            }
            .foregroundStyle(CT.Color.primary)
        }
    }

    private func sourceFallbackLabel(_ title: String) -> some View {
        Label(title, systemImage: "arrow.right.circle")
            .font(mode == .elder ? CT.Font.elderSubhead : CT.Font.subhead)
            .frame(
                minHeight: mode == .elder
                    ? CT.Size.elderTouchTarget
                    : CT.Size.secondaryButtonHeight
            )
    }

    @ViewBuilder
    private func medicationSourceLink(
        _ fact: LocalAskMedicationFact
    ) -> some View {
        switch LocalAskSourceRoute.medication(
            sourceRecordID: fact.sourceRecordID,
            medicationID: fact.id,
            availableRecordIDs: Set(records.map(\.id))
        ) {
        case let .record(recordID):
            sourceLink(recordID: recordID)
        case let .medication(medicationID):
            NavigationLink {
                MedicationAndOrdersView(
                    patientID: patientID,
                    initialMedicationID: medicationID,
                    onChanged: {
                        refreshCoordinator.sourceDidSave()
                    }
                )
            } label: {
                sourceFallbackLabel(LocalAskGeneratedCopy.viewMedication)
            }
            .foregroundStyle(CT.Color.primary)
            .accessibilityIdentifier(
                "localAsk.medicationSource.\(fact.id)"
            )
        case .followUp:
            EmptyView()
        }
    }

    @ViewBuilder
    private func followUpSourceLink(
        _ fact: LocalAskFollowUpFact
    ) -> some View {
        switch LocalAskSourceRoute.followUp(
            sourceRecordID: fact.sourceRecordID,
            followUpID: fact.id,
            availableRecordIDs: Set(records.map(\.id))
        ) {
        case let .record(recordID):
            sourceLink(recordID: recordID)
        case let .followUp(followUpID):
            NavigationLink {
                FollowUpsView(
                    patientID: patientID,
                    initialFollowUpID: followUpID,
                    onChanged: {
                        refreshCoordinator.sourceDidSave()
                    }
                )
            } label: {
                sourceFallbackLabel(LocalAskGeneratedCopy.viewFollowUp)
            }
            .foregroundStyle(CT.Color.primary)
            .accessibilityIdentifier(
                "localAsk.followUpSource.\(fact.id)"
            )
        case .medication:
            EmptyView()
        }
    }

    @MainActor
    private func prepare() async {
        isPreparing = true
        loadFailed = false
        do {
            let refreshed = try await refreshCoordinator.rebuild(
                memberID: patientID,
                activeQuery: response == nil ? nil : query,
                records: records,
                medications: medications,
                followUps: followUps
            )
            try Task.checkCancellation()
            preparedData = refreshed.preparedData
            if modelContext.hasChanges {
                try modelContext.save()
            }
            response = refreshed.response
            isPreparing = false
        } catch is CancellationError {
            AppLog.data.info("Local Ask preparation was cancelled")
        } catch {
            preparedData = nil
            isPreparing = false
            loadFailed = true
            AppLog.data.error("Local Ask could not persist its local derived index")
        }
    }

    private func runTypedQuery() {
        let bounded = LocalAskTokenizer().normalizedQuery(query)
        guard !bounded.isEmpty else { return }
        run(bounded)
    }

    private func run(_ preset: LocalAskPreset) {
        query = preset.title
        run(preset.title)
    }

    private func run(_ value: String) {
        guard let preparedData else { return }
        response = LocalAskQueryService().ask(value, in: preparedData)
    }

    private func metricGroups(
        _ facts: [LocalAskMetricFact]
    ) -> [LocalAskMetricGroup] {
        Dictionary(grouping: facts, by: \.name)
            .map { name, values in
                LocalAskMetricGroup(
                    name: name,
                    facts: values.sorted { $0.recordedAt > $1.recordedAt }
                )
            }
            .sorted { $0.name < $1.name }
    }

    private func medicationGroups(
        _ facts: [LocalAskMedicationFact]
    ) -> [LocalAskMedicationGroup] {
        Dictionary(grouping: facts, by: \.name)
            .map { name, values in
                LocalAskMedicationGroup(
                    name: name,
                    facts: values.sorted { $0.startDate < $1.startDate }
                )
            }
            .sorted { $0.name < $1.name }
    }

    private func metricValue(_ fact: LocalAskMetricFact) -> String {
        if let numericValue = fact.numericValue {
            return [
                numericValue.formatted(
                    .number.precision(.fractionLength(0...3))
                ),
                fact.unit
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        }
        return fact.textualValue ?? LocalAskGeneratedCopy.missingMetricValue
    }

    private func metricReference(_ fact: LocalAskMetricFact) -> String? {
        if let referenceText = fact.referenceText, !referenceText.isEmpty {
            return referenceText
        }
        let low = fact.referenceLow?.formatted(
            .number.precision(.fractionLength(0...3))
        )
        let high = fact.referenceHigh?.formatted(
            .number.precision(.fractionLength(0...3))
        )
        switch (low, high) {
        case let (.some(low), .some(high)): return "\(low)–\(high) \(fact.unit)"
        case let (.some(low), .none): return "≥ \(low) \(fact.unit)"
        case let (.none, .some(high)): return "≤ \(high) \(fact.unit)"
        case (.none, .none): return nil
        }
    }

    private func medicationDateLine(_ fact: LocalAskMedicationFact) -> String {
        let start = Self.dayFormatter.string(from: fact.startDate)
        if let endDate = fact.endDate {
            return "\(start) 至 \(Self.dayFormatter.string(from: endDate))"
        }
        let status = switch fact.lifecycleStatus {
        case .active: "当前在用"
        case .completed: "已完成"
        case .discontinued: "已停用"
        case .superseded: "已由后续记录替代"
        }
        return "\(start) 开始 · 原记录状态：\(status)"
    }

    private func medicationDoseLine(_ fact: LocalAskMedicationFact) -> String {
        let dose = fact.doseValue.map {
            $0.formatted(.number.precision(.fractionLength(0...3)))
        }
        let amount = [dose, fact.doseUnit]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined()
        return [amount, frequencyText(fact.frequency)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func frequencyText(_ value: FrequencyPreset) -> String {
        switch value {
        case .dailyOne: "每日 1 次"
        case .dailyTwo: "每日 2 次"
        case .dailyThree: "每日 3 次"
        case .everyOtherDay: "隔日 1 次"
        case .weekly: "每周"
        case .asNeeded: "按原记录临时使用"
        }
    }

    private var screenPadding: CGFloat {
        mode == .elder ? CT.Space.elderScreen : CT.Space.s4
    }

    private var contentSpacing: CGFloat {
        mode == .elder ? CT.Space.s6 : CT.Space.s4
    }

    private var bodyFont: Font {
        mode == .elder ? CT.Font.elderBody : CT.Font.body
    }

    private var detailFont: Font {
        mode == .elder ? CT.Font.elderFootnote : CT.Font.footnote
    }

    private var valueFont: Font {
        mode == .elder ? CT.Font.elderValueBig : CT.Font.valueMono
    }

    private static let dayFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "yyyy年M月d日"
        return value
    }()
}

private struct LocalAskMetricGroup {
    let name: String
    let facts: [LocalAskMetricFact]
}

private struct LocalAskMedicationGroup {
    let name: String
    let facts: [LocalAskMedicationFact]
}

private struct LocalAskMetricTrend: View {
    let facts: [LocalAskMetricFact]
    let mode: DisplayMode

    private var points: [LocalAskMetricFact] {
        facts
            .filter { $0.numericValue != nil }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    @ViewBuilder
    var body: some View {
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: CT.Space.s2) {
                Text("原始数值走势")
                    .font(mode == .elder ? CT.Font.elderSubhead : CT.Font.subhead)
                    .foregroundStyle(CT.Color.inkSecondary)
                Chart(points) { fact in
                    LineMark(
                        x: .value("日期", fact.recordedAt),
                        y: .value("原记录数值", fact.numericValue ?? .zero)
                    )
                    .foregroundStyle(CT.Color.primary)
                    PointMark(
                        x: .value("日期", fact.recordedAt),
                        y: .value("原记录数值", fact.numericValue ?? .zero)
                    )
                    .foregroundStyle(CT.Color.primary)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(
                    height: mode == .elder
                        ? CT.Size.elderChoiceButtonHeight
                        : CT.Size.recordCardMinHeight
                )
                .accessibilityLabel("原始数值走势，共 \(points.count) 条")
                .accessibilityIdentifier("localAsk.metric.trend")
            }
        }
    }
}

private struct LocalAskOverviewSlot: View {
    let text: String?
    let mode: DisplayMode

    @ViewBuilder
    var body: some View {
        if let text, !text.isEmpty {
            Label(text, systemImage: "text.quote")
                .font(mode == .elder ? CT.Font.elderBody : CT.Font.body)
                .foregroundStyle(CT.Color.inkPrimary)
                .padding(mode == .elder ? CT.Space.elderCard : CT.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CT.Color.bgElevated)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: mode == .elder
                            ? CT.Radius.elderCard
                            : CT.Radius.card,
                        style: .continuous
                    )
                )
                .accessibilityIdentifier("localAsk.overview")
        }
    }
}

private struct LocalAskFactCard<Content: View>: View {
    let title: String
    let systemImage: String
    let mode: DisplayMode
    /// Reserved for a future verified, device-only factual overview line.
    let overview: String?
    let accessibilityIdentifier: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: CT.Space.s3) {
            Label(title, systemImage: systemImage)
                .font(mode == .elder ? CT.Font.elderHeadline : CT.Font.headline)
                .foregroundStyle(CT.Color.inkPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(accessibilityIdentifier)
            if let overview, !overview.isEmpty {
                Text(overview)
                    .font(mode == .elder ? CT.Font.elderBody : CT.Font.body)
                    .foregroundStyle(CT.Color.inkPrimary)
            }
            content
        }
        .padding(mode == .elder ? CT.Space.elderCard : CT.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CT.Color.bgElevated)
        .clipShape(
            RoundedRectangle(
                cornerRadius: mode == .elder
                    ? CT.Radius.elderCard
                    : CT.Radius.card,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: mode == .elder
                    ? CT.Radius.elderCard
                    : CT.Radius.card,
                style: .continuous
            )
            .stroke(CT.Color.outline, lineWidth: CT.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
    }
}
