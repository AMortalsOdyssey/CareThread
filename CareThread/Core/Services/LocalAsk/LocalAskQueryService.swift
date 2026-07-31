import Foundation

final class LocalAskQueryService {
    private let indexStore: LocalAskDerivedIndexStore
    private let router: LocalAskIntentRouter
    private let timeParser: LocalAskTimeParser
    private let search: LocalAskBM25Search

    init(
        indexStore: LocalAskDerivedIndexStore = LocalAskDerivedIndexStore(),
        router: LocalAskIntentRouter = LocalAskIntentRouter(),
        timeParser: LocalAskTimeParser = LocalAskTimeParser(),
        search: LocalAskBM25Search = LocalAskBM25Search()
    ) {
        self.indexStore = indexStore
        self.router = router
        self.timeParser = timeParser
        self.search = search
    }

    /// Member filtering happens before any index is read or refreshed. This is
    /// the hard isolation boundary shared by structured and free-text paths.
    func prepare(
        memberID: UUID,
        records: [MedicalRecord],
        medications: [Medication],
        followUps: [FollowUp]
    ) -> LocalAskPreparedData {
        let scopedRecords = records
            .filter { $0.patientId == memberID }
            .map(indexStore.prepare)
        let scopedMedications = medications
            .filter { $0.patientId == memberID }
            .map(LocalAskModelAdapter.snapshot)
        let scopedFollowUps = followUps
            .filter { $0.patientId == memberID }
            .map(LocalAskModelAdapter.snapshot)

        AppLog.data.info("Local Ask prepared member-scoped local data")
        return LocalAskPreparedData(
            memberID: memberID,
            records: scopedRecords,
            medications: scopedMedications,
            followUps: scopedFollowUps
        )
    }

    @MainActor
    func prepareAsync(
        memberID: UUID,
        records: [MedicalRecord],
        medications: [Medication],
        followUps: [FollowUp]
    ) async throws -> LocalAskPreparedData {
        let scopedRecords = records.filter { $0.patientId == memberID }
        let preparedRecords = try await indexStore.prepareAsync(scopedRecords)
        try Task.checkCancellation()
        let invertedIndex = try await indexStore.makeInvertedIndexAsync(
            preparedRecords
        )
        try Task.checkCancellation()
        return LocalAskPreparedData(
            memberID: memberID,
            records: preparedRecords,
            medications: medications
                .filter { $0.patientId == memberID }
                .map(LocalAskModelAdapter.snapshot),
            followUps: followUps
                .filter { $0.patientId == memberID }
                .map(LocalAskModelAdapter.snapshot),
            invertedIndex: invertedIndex
        )
    }

    func ask(
        _ query: String,
        in prepared: LocalAskPreparedData,
        now: Date = Date()
    ) -> LocalAskResponse {
        let boundedQuery = LocalAskTokenizer().normalizedQuery(query)
        let intents = router.route(boundedQuery)
        let procedureDates = prepared.records.compactMap { record -> Date? in
            let isProcedure = record.snapshot.tags.contains { $0.kind == .procedure }
                || record.snapshot.title.contains("手术")
                || record.snapshot.summary.contains("手术")
                || record.snapshot.summary.contains("切除")
            return isProcedure ? record.snapshot.eventDate : nil
        }
        let timeScope = timeParser.parse(
            boundedQuery,
            now: now,
            procedureDates: procedureDates
        )
        let intervalRecords = prepared.records.filter {
            timeScope.contains($0.snapshot.eventDate)
        }
        let isHospitalHistory = isHospitalHistoryQuery(boundedQuery)
        var recordHits = isHospitalHistory ? [] : search.search(
            query: boundedQuery,
            index: prepared.invertedIndex,
            allowedRecordIDs: Set(intervalRecords.map { $0.snapshot.id })
        )
        recordHits = applyRecordSelection(recordHits, scope: timeScope)

        var metricFacts: [LocalAskMetricFact] = []
        if intents.contains(.metric) {
            metricFacts = queryMetrics(
                boundedQuery,
                records: prepared.records,
                scope: timeScope
            )
        }

        var medicationFacts: [LocalAskMedicationFact] = []
        if intents.contains(.medication) {
            medicationFacts = queryMedications(
                boundedQuery,
                medications: prepared.medications,
                linkedRecordHits: recordHits,
                scope: timeScope,
                now: now
            )
        }

        var followUpFacts: [LocalAskFollowUpFact] = []
        if intents.contains(.followUp) {
            followUpFacts = queryFollowUps(
                boundedQuery,
                prepared.followUps,
                scope: timeScope,
                now: now
            )
        }

        let hospitalFacts = isHospitalHistory
            ? queryHospitals(records: intervalRecords)
            : []

        AppLog.userAction.info("Local Ask completed one local factual query")
        return LocalAskResponse(
            intents: intents,
            timeScope: timeScope,
            metricFacts: metricFacts,
            medicationFacts: medicationFacts,
            followUpFacts: followUpFacts,
            hospitalFacts: hospitalFacts,
            recordHits: recordHits,
            factualOverview: nil
        )
    }

    func ask(
        _ query: String,
        memberID: UUID,
        records: [MedicalRecord],
        medications: [Medication],
        followUps: [FollowUp],
        now: Date = Date()
    ) -> LocalAskResponse {
        ask(
            query,
            in: prepare(
                memberID: memberID,
                records: records,
                medications: medications,
                followUps: followUps
            ),
            now: now
        )
    }

    private func queryMetrics(
        _ query: String,
        records: [LocalAskPreparedRecord],
        scope: LocalAskTimeScope
    ) -> [LocalAskMetricFact] {
        let requestedEntries = MedicalSynonymLexicon.matches(
            in: query,
            category: .metric
        )
        var facts = records
            .flatMap { $0.snapshot.measurements }
            .filter { scope.contains($0.recordedAt) }
            .filter { fact in
                requestedEntries.isEmpty || requestedEntries.contains { entry in
                    entry.allTerms.contains { term in
                        let normalizedFact = MedicalSynonymLexicon.normalizeForMatching(fact.name)
                        let normalizedTerm = MedicalSynonymLexicon.normalizeForMatching(term)
                        return normalizedFact.contains(normalizedTerm)
                            || normalizedTerm.contains(normalizedFact)
                    }
                }
            }
            .sorted {
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        facts = applyFactSelection(facts, scope: scope, date: \.recordedAt)
        return facts
    }

    private func queryMedications(
        _ query: String,
        medications: [LocalAskMedicationSnapshot],
        linkedRecordHits: [LocalAskRecordHit],
        scope: LocalAskTimeScope,
        now: Date
    ) -> [LocalAskMedicationFact] {
        let requestedEntries = MedicalSynonymLexicon.matches(
            in: query,
            category: .medication
        )
        let hitIDs = Set(linkedRecordHits.map(\.recordID))
        let isFreeTextAssociation = router.route(query).contains(.freeText)

        var facts = medications
            .filter { medication in
                if !requestedEntries.isEmpty {
                    return requestedEntries.contains { entry in
                        entry.allTerms.contains { term in
                            let name = MedicalSynonymLexicon.normalizeForMatching(medication.name)
                            let candidate = MedicalSynonymLexicon.normalizeForMatching(term)
                            return name.contains(candidate) || candidate.contains(name)
                        }
                    }
                }
                if isFreeTextAssociation, !hitIDs.isEmpty {
                    return medication.sourceRecordID.map(hitIDs.contains) ?? false
                }
                return true
            }
            .filter { medication in
                guard isCurrentMedicationQuery(query) else { return true }
                return medication.lifecycleStatus == .active
                    && medication.startDate <= now
                    && (medication.endDate.map { now < $0 } ?? true)
            }
            .filter { medicationOverlapsScope($0, scope: scope) }
            .map {
                LocalAskMedicationFact(
                    id: $0.id,
                    sourceRecordID: $0.sourceRecordID,
                    name: $0.name,
                    doseValue: $0.doseValue,
                    doseUnit: $0.doseUnit,
                    frequency: $0.frequency,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    lifecycleStatus: $0.lifecycleStatus
                )
            }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                return $0.id.uuidString < $1.id.uuidString
            }
        facts = applyFactSelection(facts, scope: scope, date: \.startDate)
        return facts
    }

    private func medicationOverlapsScope(
        _ medication: LocalAskMedicationSnapshot,
        scope: LocalAskTimeScope
    ) -> Bool {
        guard let interval = scope.interval else { return true }
        guard medication.startDate < interval.end else { return false }
        guard let endDate = medication.endDate else { return true }
        return endDate > interval.start
    }

    private func queryFollowUps(
        _ query: String,
        _ followUps: [LocalAskFollowUpSnapshot],
        scope: LocalAskTimeScope,
        now: Date
    ) -> [LocalAskFollowUpFact] {
        var facts = followUps
            .filter { scope.contains($0.plannedDate) }
            .filter { followUp in
                guard isNextFollowUpQuery(query) else { return true }
                let startOfToday = timeParser.startOfDay(for: now)
                return followUp.status == .pending
                    && followUp.plannedDate >= startOfToday
            }
            .map {
                LocalAskFollowUpFact(
                    id: $0.id,
                    sourceRecordID: $0.sourceRecordID,
                    plannedDate: $0.plannedDate,
                    items: $0.items,
                    status: $0.status,
                    completedAt: $0.completedAt
                )
            }
            .sorted {
                if $0.plannedDate != $1.plannedDate { return $0.plannedDate < $1.plannedDate }
                return $0.id.uuidString < $1.id.uuidString
            }
        facts = applyFactSelection(facts, scope: scope, date: \.plannedDate)
        if isNextFollowUpQuery(query),
           let nextDay = facts.map({
               timeParser.startOfDay(for: $0.plannedDate)
           }).min() {
            return facts.filter {
                timeParser.startOfDay(for: $0.plannedDate) == nextDay
            }
        }
        return facts
    }

    private func isCurrentMedicationQuery(_ query: String) -> Bool {
        ["在吃什么药", "正在吃", "现在吃", "目前吃", "当前用药"].contains {
            query.contains($0)
        }
    }

    private func isNextFollowUpQuery(_ query: String) -> Bool {
        query.contains("下次")
    }

    private func isHospitalHistoryQuery(_ query: String) -> Bool {
        query.contains("哪些医院")
            || query.contains("哪家医院")
            || query.contains("去过什么医院")
            || query.contains("去过的医院")
            || query.contains("看过哪些医院")
            || query.contains("就诊过哪些医院")
    }

    private func queryHospitals(
        records: [LocalAskPreparedRecord]
    ) -> [LocalAskHospitalFact] {
        struct Aggregate {
            var displayName: String
            var latestRecordID: UUID
            var latestVisitAt: Date
            var visitCount: Int
        }

        var aggregates: [String: Aggregate] = [:]
        for record in records {
            guard let rawName = record.snapshot.hospital?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !rawName.isEmpty else {
                continue
            }
            let key = MemberIdentity.normalize(rawName)
            if var existing = aggregates[key] {
                existing.visitCount += 1
                if record.snapshot.eventDate > existing.latestVisitAt
                    || (record.snapshot.eventDate == existing.latestVisitAt
                        && record.snapshot.id.uuidString < existing.latestRecordID.uuidString) {
                    existing.displayName = rawName
                    existing.latestRecordID = record.snapshot.id
                    existing.latestVisitAt = record.snapshot.eventDate
                }
                aggregates[key] = existing
            } else {
                aggregates[key] = Aggregate(
                    displayName: rawName,
                    latestRecordID: record.snapshot.id,
                    latestVisitAt: record.snapshot.eventDate,
                    visitCount: 1
                )
            }
        }

        return aggregates.values.map {
            LocalAskHospitalFact(
                name: $0.displayName,
                latestVisitAt: $0.latestVisitAt,
                visitCount: $0.visitCount,
                sourceRecordID: $0.latestRecordID
            )
        }
        .sorted {
            if $0.latestVisitAt != $1.latestVisitAt {
                return $0.latestVisitAt > $1.latestVisitAt
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func applyRecordSelection(
        _ hits: [LocalAskRecordHit],
        scope: LocalAskTimeScope
    ) -> [LocalAskRecordHit] {
        switch scope.selection {
        case .mostRecent:
            guard let date = hits.map(\.eventDate).max() else { return [] }
            return hits.filter { $0.eventDate == date }
        case .earliest:
            guard let date = hits.map(\.eventDate).min() else { return [] }
            return hits.filter { $0.eventDate == date }
        case .allTime, .interval:
            return hits
        }
    }

    private func applyFactSelection<Value>(
        _ values: [Value],
        scope: LocalAskTimeScope,
        date: KeyPath<Value, Date>
    ) -> [Value] {
        switch scope.selection {
        case .mostRecent:
            guard let selected = values.map({ $0[keyPath: date] }).max() else { return [] }
            return values.filter { $0[keyPath: date] == selected }
        case .earliest:
            guard let selected = values.map({ $0[keyPath: date] }).min() else { return [] }
            return values.filter { $0[keyPath: date] == selected }
        case .allTime, .interval:
            return values
        }
    }
}
