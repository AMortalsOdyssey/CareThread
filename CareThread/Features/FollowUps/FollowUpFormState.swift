import Foundation

enum FollowUpFormValidation: Equatable {
    case valid
    case missingItems
    case dateInPast

    var message: String? {
        switch self {
        case .valid: nil
        case .missingItems: Copy.FollowUp.missingItems
        case .dateInPast: Copy.FollowUp.futureDateRequired
        }
    }
}

struct FollowUpFormState: Equatable {
    var plannedDate: Date
    var itemsText: String
    var reason: String
    var bringRecordIDs: Set<UUID>
    var compareRecordID: UUID?
    var reminderEnabled: Bool

    init(now: Date = Date()) {
        plannedDate = Calendar.current.date(
            byAdding: .month,
            value: 3,
            to: now
        ) ?? now
        itemsText = ""
        reason = ""
        bringRecordIDs = []
        compareRecordID = nil
        reminderEnabled = true
    }

    init(followUp: FollowUp) {
        plannedDate = followUp.plannedDate
        itemsText = followUp.items.joined(separator: "、")
        reason = followUp.reason ?? ""
        bringRecordIDs = Set(followUp.bringRecordIds)
        compareRecordID = followUp.compareRecordId
        reminderEnabled = followUp.reminderEnabled
    }

    var items: [String] {
        itemsText
            .components(separatedBy: CharacterSet(charactersIn: "、,，\n"))
            .compactMap {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
    }

    func validation(
        now: Date,
        calendar: Calendar = .current
    ) -> FollowUpFormValidation {
        guard !items.isEmpty else { return .missingItems }
        guard calendar.startOfDay(for: plannedDate) >=
                calendar.startOfDay(for: now) else {
            return .dateInPast
        }
        return .valid
    }

    func editableContent(
        from followUp: FollowUp,
        now: Date
    ) -> FollowUpEditableContent? {
        guard validation(now: now) == .valid else { return nil }
        var value = followUp.editableContent()
        value.plannedDate = plannedDate
        value.items = items
        value.reason = nilIfEmpty(reason)
        value.bringRecordIds = Array(bringRecordIDs).sorted {
            $0.uuidString < $1.uuidString
        }
        value.compareRecordId = compareRecordID
        value.reminderEnabled = reminderEnabled
        value.updatedAt = now
        return value
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct FollowUpSections: Equatable {
    var overdue: [UUID]
    var nextThirtyDays: [UUID]
    var later: [UUID]
    var completed: [UUID]

    static func make(
        followUps: [FollowUp],
        now: Date,
        calendar: Calendar = .current
    ) -> FollowUpSections {
        let today = calendar.startOfDay(for: now)
        let boundary = calendar.date(
            byAdding: .day,
            value: 30,
            to: today
        ) ?? today
        var overdue: [FollowUp] = []
        var next: [FollowUp] = []
        var later: [FollowUp] = []
        var completed: [FollowUp] = []
        for followUp in followUps {
            let plannedDay = calendar.startOfDay(for: followUp.plannedDate)
            if followUp.status == .completed {
                completed.append(followUp)
            } else if plannedDay < today {
                overdue.append(followUp)
            } else if plannedDay <= boundary {
                next.append(followUp)
            } else {
                later.append(followUp)
            }
        }
        return FollowUpSections(
            overdue: overdue
                .sorted { $0.plannedDate < $1.plannedDate }
                .map(\.id),
            nextThirtyDays: next
                .sorted { $0.plannedDate < $1.plannedDate }
                .map(\.id),
            later: later
                .sorted { $0.plannedDate < $1.plannedDate }
                .map(\.id),
            completed: completed
                .sorted { $0.plannedDate > $1.plannedDate }
                .map(\.id)
        )
    }
}
