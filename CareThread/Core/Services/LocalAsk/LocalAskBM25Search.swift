import Foundation

struct LocalAskBM25Search {
    private let tokenizer: LocalAskTokenizer
    private let k1 = 1.2
    private let b = 0.75

    init(tokenizer: LocalAskTokenizer = LocalAskTokenizer()) {
        self.tokenizer = tokenizer
    }

    func search(
        query: String,
        index: LocalAskInvertedIndex,
        allowedRecordIDs: Set<UUID>,
        limit: Int = 20
    ) -> [LocalAskRecordHit] {
        let queryTerms = orderedUnique(tokenizer.terms(in: query, isQuery: true))
        guard !queryTerms.isEmpty,
              !allowedRecordIDs.isEmpty,
              limit > 0 else { return [] }

        let documentCount = Double(allowedRecordIDs.count)
        let averageLength = max(
            1,
            Double(allowedRecordIDs.reduce(0) {
                $0 + (index.documentTermCounts[$1] ?? 0)
            }) / documentCount
        )
        var documentFrequencies: [String: Int] = [:]
        for term in queryTerms {
            documentFrequencies[term] = (index.postingsByTerm[term] ?? [])
                .reduce(0) { count, posting in
                    count + (allowedRecordIDs.contains(posting.recordID) ? 1 : 0)
                }
        }
        let candidateIDs = index.candidateRecordIDs(
            for: queryTerms,
            allowedRecordIDs: allowedRecordIDs
        )

        return candidateIDs.compactMap { recordID -> LocalAskRecordHit? in
            guard let record = index.recordsByID[recordID] else { return nil }
            let length = Double(record.document.termCount)
            var score = 0.0
            var matchedTerms: [String] = []
            for term in queryTerms {
                guard let frequency = record.document.weightedTermFrequencies[term],
                      frequency > 0 else {
                    continue
                }
                let df = Double(documentFrequencies[term] ?? 0)
                let inverseDocumentFrequency = log(
                    1 + (documentCount - df + 0.5) / (df + 0.5)
                )
                let denominator = frequency
                    + k1 * (1 - b + b * length / averageLength)
                score += inverseDocumentFrequency * frequency * (k1 + 1) / denominator
                matchedTerms.append(MedicalSynonymLexicon.displayTerm(for: term))
            }
            guard score > 0 else { return nil }
            return LocalAskRecordHit(
                recordID: record.snapshot.id,
                title: record.snapshot.title,
                summary: record.snapshot.summary,
                eventDate: record.snapshot.eventDate,
                score: score,
                matchedTerms: orderedUnique(matchedTerms)
            )
        }
        .sorted {
            if abs($0.score - $1.score) > 0.000_001 {
                return $0.score > $1.score
            }
            if $0.eventDate != $1.eventDate {
                return $0.eventDate > $1.eventDate
            }
            return $0.recordID.uuidString < $1.recordID.uuidString
        }
        .prefix(limit)
        .map { $0 }
    }

    func candidateRecordIDs(
        query: String,
        index: LocalAskInvertedIndex,
        allowedRecordIDs: Set<UUID>
    ) -> Set<UUID> {
        let terms = orderedUnique(tokenizer.terms(in: query, isQuery: true))
        return index.candidateRecordIDs(
            for: terms,
            allowedRecordIDs: allowedRecordIDs
        )
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
