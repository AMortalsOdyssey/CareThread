import Foundation

struct FollowUpRecordReference: Identifiable, Equatable {
    enum Availability: Equatable {
        case available(title: String)
        case deleted
    }

    let id: UUID
    let availability: Availability

    var displayTitle: String {
        switch availability {
        case let .available(title):
            title
        case .deleted:
            Copy.FollowUp.deletedRecord
        }
    }

    var isDeleted: Bool {
        availability == .deleted
    }
}

enum FollowUpRecordReferenceResolver {
    /// Preserves the follow-up's stored order and emits a tombstone whenever
    /// the referenced record no longer exists. The UUID remains in the
    /// follow-up so an old plan never silently changes meaning.
    static func resolve(
        ids: [UUID],
        availableRecords: [MedicalRecord]
    ) -> [FollowUpRecordReference] {
        let titles = Dictionary(
            uniqueKeysWithValues: availableRecords.map {
                ($0.id, $0.displayTitle)
            }
        )
        return ids.map { id in
            if let title = titles[id] {
                FollowUpRecordReference(
                    id: id,
                    availability: .available(title: title)
                )
            } else {
                FollowUpRecordReference(id: id, availability: .deleted)
            }
        }
    }
}
