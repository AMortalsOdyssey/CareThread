import Foundation

protocol LocalAskIndexBuilding {
    var algorithmVersion: String { get }

    func makeDocument(
        from snapshot: LocalAskRecordSnapshot,
        sourceRevision: Int
    ) -> LocalAskIndexedDocument
}

struct LocalAskTextIndexBuilder: LocalAskIndexBuilding, Sendable {
    static let currentAlgorithmVersion = "local-ask-bm25-nltokenizer-v1"

    var algorithmVersion: String
    private let tokenizer: LocalAskTokenizer

    init(
        algorithmVersion: String = Self.currentAlgorithmVersion,
        tokenizer: LocalAskTokenizer = LocalAskTokenizer()
    ) {
        self.algorithmVersion = algorithmVersion
        self.tokenizer = tokenizer
    }

    func makeDocument(
        from snapshot: LocalAskRecordSnapshot,
        sourceRevision: Int
    ) -> LocalAskIndexedDocument {
        makeDocument(from: makeInput(
            from: snapshot,
            sourceRevision: sourceRevision
        ))
    }

    func makeInput(
        from snapshot: LocalAskRecordSnapshot,
        sourceRevision: Int
    ) -> LocalAskIndexInput {
        let diagnosisText = ([snapshot.primaryDisease].compactMap { $0 }
            + snapshot.tags.filter { $0.kind == .disease }.map(\.value))
            .joined(separator: " ")
        let structuredParts: [String?] = [
            snapshot.type.displayName,
            snapshot.hospital,
            snapshot.department,
            snapshot.doctor,
            snapshot.structuredFields.map { "\($0.key) \($0.value)" }.joined(separator: " "),
            snapshot.measurements.map {
                let value = $0.numericValue.map { "\($0)" }
                    ?? $0.textualValue
                    ?? ""
                return "\($0.name) \(value) \($0.unit)"
            }.joined(separator: " "),
            snapshot.tags.map(\.value).joined(separator: " ")
        ]
        let structuredText = structuredParts
            .compactMap { $0 }
            .joined(separator: " ")
        var fragments = [
            LocalAskWeightedText(text: snapshot.title, weight: 3),
            LocalAskWeightedText(text: snapshot.summary, weight: 2),
            LocalAskWeightedText(text: diagnosisText, weight: 2),
            LocalAskWeightedText(text: structuredText, weight: 1.5)
        ]
        if let ocrText = snapshot.ocrText {
            fragments.append(
                LocalAskWeightedText(
                    text: String(ocrText.prefix(200_000)),
                    weight: 1
                )
            )
        }
        return LocalAskIndexInput(
            recordID: snapshot.id,
            sourceRevision: sourceRevision,
            fragments: fragments
        )
    }

    func makeDocument(from input: LocalAskIndexInput) -> LocalAskIndexedDocument {
        var weightedFrequencies: [String: Double] = [:]
        var termCount = 0
        for fragment in input.fragments {
            append(
                fragment.text,
                weight: fragment.weight,
                to: &weightedFrequencies,
                termCount: &termCount
            )
        }
        return LocalAskIndexedDocument(
            recordID: input.recordID,
            sourceRevision: input.sourceRevision,
            weightedTermFrequencies: weightedFrequencies,
            termCount: max(1, termCount)
        )
    }

    private func append(
        _ text: String,
        weight: Double,
        to frequencies: inout [String: Double],
        termCount: inout Int
    ) {
        let terms = tokenizer.terms(in: text)
        termCount += terms.count
        for term in terms {
            frequencies[term, default: 0] += weight
        }
    }
}

enum LocalAskIndexWorkerPhase: Equatable, Sendable {
    case makeInput
    case tokenize
    case postings
}

enum LocalAskIndexPreparationError: Error, Equatable {
    case sourceKeptChanging
}

final class LocalAskDerivedIndexStore {
    private static let maximumParallelBuildWorkers = 8
    private static let minimumParallelChunkSize = 50
    private static let maximumBuildRounds = 2
    private let builder: any LocalAskIndexBuilding
    private let workerEvent: @Sendable (LocalAskIndexWorkerPhase) -> Void

    init(
        builder: any LocalAskIndexBuilding = LocalAskTextIndexBuilder(),
        workerEvent: @escaping @Sendable (LocalAskIndexWorkerPhase) -> Void = { _ in }
    ) {
        self.builder = builder
        self.workerEvent = workerEvent
    }

    func prepare(_ record: MedicalRecord) -> LocalAskPreparedRecord {
        let snapshot = LocalAskModelAdapter.snapshot(record)
        let sourceRevision = record.contentRevision

        if record.derivedTextIndexAlgorithmVersion == builder.algorithmVersion,
           record.derivedTextIndexSourceRevision == sourceRevision,
           let payload = record.derivedTextIndexPayload,
           let document = ModelPayload.read(
                LocalAskIndexedDocument.self,
                from: payload
           ).value,
           document.recordID == record.id,
           document.sourceRevision == sourceRevision {
            return LocalAskPreparedRecord(snapshot: snapshot, document: document)
        }

        let document = builder.makeDocument(
            from: snapshot,
            sourceRevision: sourceRevision
        )
        record.replaceDerivedTextIndex(
            payload: ModelPayload.requiredEncode(document),
            algorithmVersion: builder.algorithmVersion,
            sourceRevision: sourceRevision
        )
        return LocalAskPreparedRecord(snapshot: snapshot, document: document)
    }

    @MainActor
    func prepareAsync(
        _ records: [MedicalRecord]
    ) async throws -> [LocalAskPreparedRecord] {
        guard let textBuilder = builder as? LocalAskTextIndexBuilder else {
            return records.map(prepare)
        }

        struct Slot {
            var position: Int
            var record: MedicalRecord
            var snapshot: LocalAskRecordSnapshot
            var sourceRevision: Int
            var document: LocalAskIndexedDocument?
            var needsCommit: Bool
        }
        struct WorkItem: Sendable {
            var position: Int
            var snapshot: LocalAskRecordSnapshot
            var sourceRevision: Int
        }

        let algorithmVersion = textBuilder.algorithmVersion
        var slots: [Slot] = []
        slots.reserveCapacity(records.count)
        var work: [WorkItem] = []
        work.reserveCapacity(records.count)
        for (position, record) in records.enumerated() {
            try Task.checkCancellation()
            let snapshot = LocalAskModelAdapter.snapshot(record)
            let sourceRevision = record.contentRevision
            let storedDocument: LocalAskIndexedDocument?
            if record.derivedTextIndexAlgorithmVersion == algorithmVersion,
               record.derivedTextIndexSourceRevision == sourceRevision,
               let payload = record.derivedTextIndexPayload,
               let document = ModelPayload.read(
                    LocalAskIndexedDocument.self,
                    from: payload
               ).value,
               document.recordID == record.id,
               document.sourceRevision == sourceRevision {
                storedDocument = document
            } else {
                storedDocument = nil
            }
            slots.append(Slot(
                position: position,
                record: record,
                snapshot: snapshot,
                sourceRevision: sourceRevision,
                document: storedDocument,
                needsCommit: storedDocument == nil
            ))
            if storedDocument == nil {
                work.append(WorkItem(
                    position: position,
                    snapshot: snapshot,
                    sourceRevision: sourceRevision
                ))
            }
        }

        // A record can be edited while the detached build is running. Any
        // changed shard is recaptured and re-dispatched; no stale shard is
        // tokenized on MainActor and nothing is persisted until all slots are
        // stable in one synchronous commit boundary.
        var buildRound = 0
        while !work.isEmpty {
            guard buildRound < Self.maximumBuildRounds else {
                AppLog.data.warning(
                    "Local Ask index source kept changing; no shards were committed"
                )
                throw LocalAskIndexPreparationError.sourceKeptChanging
            }
            buildRound += 1
            let roundWork = work
            let workerEvent = workerEvent
            let worker = Task.detached(priority: .userInitiated) {
                let workerCount = min(
                    Self.maximumParallelBuildWorkers,
                    max(1, roundWork.count / Self.minimumParallelChunkSize)
                )
                let chunkSize = max(
                    1,
                    Int(ceil(Double(roundWork.count) / Double(workerCount)))
                )
                return try await withThrowingTaskGroup(
                    of: [(Int, LocalAskIndexedDocument)].self
                ) { group in
                    for start in stride(
                        from: 0,
                        to: roundWork.count,
                        by: chunkSize
                    ) {
                        let end = min(start + chunkSize, roundWork.count)
                        let chunk = Array(roundWork[start..<end])
                        group.addTask {
                            try chunk.map { item in
                                try Task.checkCancellation()
                                workerEvent(.makeInput)
                                let input = textBuilder.makeInput(
                                    from: item.snapshot,
                                    sourceRevision: item.sourceRevision
                                )
                                workerEvent(.tokenize)
                                return (
                                    item.position,
                                    textBuilder.makeDocument(from: input)
                                )
                            }
                        }
                    }
                    var documents: [(Int, LocalAskIndexedDocument)] = []
                    documents.reserveCapacity(roundWork.count)
                    for try await chunk in group {
                        documents.append(contentsOf: chunk)
                    }
                    return documents
                }
            }
            defer { worker.cancel() }
            let documents = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let documentsByPosition = Dictionary(
                uniqueKeysWithValues: documents
            )
            for index in slots.indices {
                if let document = documentsByPosition[slots[index].position] {
                    slots[index].document = document
                    slots[index].needsCommit = true
                }
            }

            var retryWork: [WorkItem] = []
            for index in slots.indices {
                try Task.checkCancellation()
                guard slots[index].record.contentRevision
                        != slots[index].sourceRevision else {
                    continue
                }
                AppLog.data.warning(
                    "Local Ask re-dispatched a stale derived-index shard"
                )
                let record = slots[index].record
                let snapshot = LocalAskModelAdapter.snapshot(record)
                let sourceRevision = record.contentRevision
                slots[index].snapshot = snapshot
                slots[index].sourceRevision = sourceRevision

                if record.derivedTextIndexAlgorithmVersion == algorithmVersion,
                   record.derivedTextIndexSourceRevision == sourceRevision,
                   let payload = record.derivedTextIndexPayload,
                   let document = ModelPayload.read(
                       LocalAskIndexedDocument.self,
                       from: payload
                   ).value,
                   document.recordID == record.id,
                   document.sourceRevision == sourceRevision {
                    slots[index].document = document
                    slots[index].needsCommit = false
                } else {
                    slots[index].document = nil
                    slots[index].needsCommit = true
                    retryWork.append(WorkItem(
                        position: slots[index].position,
                        snapshot: snapshot,
                        sourceRevision: sourceRevision
                    ))
                }
            }
            work = retryWork
        }

        // Atomic cancellation boundary: all work above is read-only or pure
        // calculation. This synchronous loop either commits every stable shard
        // and returns, or cancellation is observed before any shard is written.
        try Task.checkCancellation()
        var prepared: [LocalAskPreparedRecord] = []
        prepared.reserveCapacity(slots.count)
        for slot in slots.sorted(by: { $0.position < $1.position }) {
            guard let document = slot.document else {
                assertionFailure("Local Ask build completed without a document")
                continue
            }
            if slot.needsCommit {
                slot.record.replaceDerivedTextIndex(
                    payload: ModelPayload.requiredEncode(document),
                    algorithmVersion: algorithmVersion,
                    sourceRevision: slot.sourceRevision
                )
            }
            var responseSnapshot = slot.snapshot
            responseSnapshot.ocrText = nil
            prepared.append(LocalAskPreparedRecord(
                snapshot: responseSnapshot,
                document: document
            ))
        }
        return prepared
    }

    func makeInvertedIndexAsync(
        _ records: [LocalAskPreparedRecord]
    ) async throws -> LocalAskInvertedIndex {
        let workerEvent = workerEvent
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            workerEvent(.postings)
            let index = LocalAskInvertedIndex(records: records)
            try Task.checkCancellation()
            return index
        }
        defer { worker.cancel() }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

enum LocalAskModelAdapter {
    static func snapshot(_ record: MedicalRecord) -> LocalAskRecordSnapshot {
        let editable = record.editableContent()
        let measurements = record.measurements.map { measurement in
            let value = measurement.editableContent()
            return LocalAskMetricFact(
                id: measurement.id,
                sourceRecordID: record.id,
                name: value.displayName,
                numericValue: value.numericValue,
                textualValue: value.textualValue,
                unit: value.unit,
                referenceLow: value.referenceLow,
                referenceHigh: value.referenceHigh,
                referenceText: value.referenceText,
                abnormalState: value.abnormalState,
                recordedAt: value.eventDate
            )
        }
        return LocalAskRecordSnapshot(
            id: record.id,
            patientID: record.patientId,
            title: editable.title,
            summary: editable.summary,
            eventDate: editable.eventDate,
            type: editable.type,
            hospital: editable.hospital,
            department: editable.department,
            doctor: editable.doctor,
            primaryDisease: editable.primaryDisease,
            ocrText: record.ocrText,
            structuredFields: editable.structuredFields,
            measurements: measurements,
            tags: record.tags.map {
                LocalAskTagSnapshot(kind: $0.kind, value: $0.editableContent().displayValue)
            }
        )
    }

    static func snapshot(_ medication: Medication) -> LocalAskMedicationSnapshot {
        let editable = medication.editableContent()
        return LocalAskMedicationSnapshot(
            id: medication.id,
            patientID: medication.patientId,
            sourceRecordID: medication.sourceRecordId,
            name: editable.name,
            doseValue: editable.doseValue,
            doseUnit: editable.doseUnit,
            frequency: editable.frequency,
            startDate: editable.startDate,
            endDate: editable.endDate,
            lifecycleStatus: editable.lifecycleStatus
        )
    }

    static func snapshot(_ followUp: FollowUp) -> LocalAskFollowUpSnapshot {
        let editable = followUp.editableContent()
        return LocalAskFollowUpSnapshot(
            id: followUp.id,
            patientID: followUp.patientId,
            sourceRecordID: editable.resultRecordId ?? editable.compareRecordId,
            plannedDate: editable.plannedDate,
            items: editable.items,
            status: editable.status,
            completedAt: editable.completedAt
        )
    }
}
