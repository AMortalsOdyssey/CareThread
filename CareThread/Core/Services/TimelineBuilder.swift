import Foundation
import SwiftData

enum TimelineFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case abnormal
    case records
    case medications
    case followUps

    var id: String { rawValue }
}

struct TimelineEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case medicalRecord
        case medicationStarted
        case medicationAdjusted
        case medicationStopped
        case medicalOrder
        case followUpDue
        case followUpCompleted

        fileprivate var stablePriority: Int {
            switch self {
            case .medicalRecord: 0
            case .medicationAdjusted: 1
            case .medicationStarted: 2
            case .medicationStopped: 3
            case .medicalOrder: 4
            case .followUpCompleted: 5
            case .followUpDue: 6
            }
        }
    }

    enum Destination: Equatable, Sendable {
        case record(UUID)
        case medication(UUID)
        case medicalOrder(UUID)
        case followUp(UUID)
    }

    let sourceID: UUID
    let patientID: UUID
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    let recordType: RecordType?
    let isAbnormal: Bool
    let isOverdue: Bool
    let destination: Destination

    var id: String {
        "\(kind.rawValue):\(sourceID.uuidString)"
    }

    fileprivate var category: TimelineFilter {
        switch kind {
        case .medicalRecord:
            .records
        case .medicationStarted, .medicationAdjusted, .medicationStopped:
            .medications
        case .medicalOrder, .followUpDue, .followUpCompleted:
            .followUps
        }
    }
}

struct TimelinePageRequest: Equatable, Sendable {
    let offset: Int
    let limit: Int

    init(offset: Int = 0, limit: Int = TimelineQueryPolicy.defaultPageSize) {
        self.offset = max(0, offset)
        self.limit = min(
            max(1, limit),
            TimelineQueryPolicy.maximumPageSize
        )
    }
}

struct TimelinePage {
    let events: [TimelineEvent]
    let hasMore: Bool
}

enum TimelineQueryPolicy {
    static let defaultPageSize = 30
    static let maximumPageSize = 100
    static let maximumSourceRows = 600
    static let maximumTimelineEvents = 1_200
}

@MainActor
enum TimelineBuilder {
    static func build(
        patientID: UUID,
        records: [MedicalRecord],
        medications: [Medication],
        orders: [MedicalOrder],
        followUps: [FollowUp],
        now: Date,
        calendar: Calendar = CTDate.calendar
    ) -> [TimelineEvent] {
        var values: [TimelineEvent] = []

        values.append(
            contentsOf: records
                .filter { $0.patientId == patientID }
                .map(recordEvent)
        )

        let scopedMedications = medications.filter {
            $0.patientId == patientID
        }
        values.append(
            contentsOf: medicationEvents(
                scopedMedications,
                patientID: patientID
            )
        )

        values.append(
            contentsOf: orders
                .filter { $0.patientId == patientID }
                .map(orderEvent)
        )

        for followUp in followUps where followUp.patientId == patientID {
            values.append(
                contentsOf: followUpEvents(
                    followUp,
                    now: now,
                    calendar: calendar
                )
            )
        }

        return values.sorted(by: stableOrder)
    }

    static func apply(
        _ filter: TimelineFilter,
        to events: [TimelineEvent]
    ) -> [TimelineEvent] {
        switch filter {
        case .all:
            events
        case .abnormal:
            events.filter(\.isAbnormal)
        case .records, .medications, .followUps:
            events.filter { $0.category == filter }
        }
    }

    private static func recordEvent(
        _ record: MedicalRecord
    ) -> TimelineEvent {
        let abnormal = !record.abnormalFlags.isEmpty
            || record.labItems.contains { $0.flag != .none }
        let trimmedTitle = record.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let detail = record.summary.isEmpty
            ? record.type.displayName
            : record.summary
        return TimelineEvent(
            sourceID: record.id,
            patientID: record.patientId,
            date: record.eventDate,
            kind: .medicalRecord,
            title: trimmedTitle.isEmpty
                ? record.type.displayName
                : trimmedTitle,
            detail: detail,
            recordType: record.type,
            isAbnormal: abnormal,
            isOverdue: false,
            destination: .record(record.id)
        )
    }

    private static func medicationEvents(
        _ medications: [Medication],
        patientID: UUID
    ) -> [TimelineEvent] {
        let medicationByID = Dictionary(
            uniqueKeysWithValues: medications.map { ($0.id, $0) }
        )
        let successorsByPreviousID = Dictionary(
            grouping: medications.compactMap { medication -> (UUID, Medication)? in
                guard let previousID = medication.previousVersionId,
                      medicationByID[previousID] != nil else {
                    return nil
                }
                return (previousID, medication)
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }

        var values: [TimelineEvent] = []
        for medication in medications {
            if let previousID = medication.previousVersionId,
               let previous = medicationByID[previousID] {
                values.append(
                    TimelineEvent(
                        sourceID: medication.id,
                        patientID: patientID,
                        date: medication.startDate,
                        kind: .medicationAdjusted,
                        title: Copy.Timeline.medicationAdjusted,
                        detail: Copy.Timeline.adjustmentDetail(
                            name: medication.name,
                            from: doseText(previous),
                            to: doseText(medication)
                        ),
                        recordType: nil,
                        isAbnormal: false,
                        isOverdue: false,
                        destination: .medication(medication.id)
                    )
                )
            } else {
                values.append(
                    TimelineEvent(
                        sourceID: medication.id,
                        patientID: patientID,
                        date: medication.startDate,
                        kind: .medicationStarted,
                        title: Copy.Timeline.medicationStarted,
                        detail: Copy.Timeline.medicationDetail(
                            name: medication.name,
                            dose: doseText(medication)
                        ),
                        recordType: nil,
                        isAbnormal: false,
                        isOverdue: false,
                        destination: .medication(medication.id)
                    )
                )
            }

            guard let endDate = medication.endDate else { continue }
            let hasSameMomentAdjustment = successorsByPreviousID[
                medication.id
            ]?.contains {
                $0.patientId == patientID && $0.startDate == endDate
            } ?? false
            guard !hasSameMomentAdjustment else { continue }
            values.append(
                TimelineEvent(
                    sourceID: medication.id,
                    patientID: patientID,
                    date: endDate,
                    kind: .medicationStopped,
                    title: Copy.Timeline.medicationStopped,
                    detail: Copy.Timeline.medicationDetail(
                        name: medication.name,
                        dose: doseText(medication)
                    ),
                    recordType: nil,
                    isAbnormal: false,
                    isOverdue: false,
                    destination: .medication(medication.id)
                )
            )
        }
        return values
    }

    private static func orderEvent(
        _ order: MedicalOrder
    ) -> TimelineEvent {
        TimelineEvent(
            sourceID: order.id,
            patientID: order.patientId,
            date: order.createdAt,
            kind: .medicalOrder,
            title: Copy.Timeline.medicalOrderCreated,
            detail: order.content,
            recordType: nil,
            isAbnormal: false,
            isOverdue: false,
            destination: .medicalOrder(order.id)
        )
    }

    private static func followUpEvents(
        _ followUp: FollowUp,
        now: Date,
        calendar: Calendar
    ) -> [TimelineEvent] {
        let today = calendar.startOfDay(for: now)
        let plannedDay = calendar.startOfDay(for: followUp.plannedDate)
        let overdue = followUp.status == .pending && plannedDay < today
        var values = [
            TimelineEvent(
                sourceID: followUp.id,
                patientID: followUp.patientId,
                date: followUp.plannedDate,
                kind: .followUpDue,
                title: overdue
                    ? Copy.Timeline.followUpOverdue
                    : Copy.Timeline.followUpDue,
                detail: Copy.Timeline.items(followUp.items),
                recordType: nil,
                isAbnormal: false,
                isOverdue: overdue,
                destination: .followUp(followUp.id)
            )
        ]
        if followUp.status == .completed, let completedAt = followUp.completedAt {
            values.append(
                TimelineEvent(
                    sourceID: followUp.id,
                    patientID: followUp.patientId,
                    date: completedAt,
                    kind: .followUpCompleted,
                    title: Copy.Timeline.followUpCompleted,
                    detail: Copy.Timeline.items(followUp.items),
                    recordType: nil,
                    isAbnormal: false,
                    isOverdue: false,
                    destination: .followUp(followUp.id)
                )
            )
        }
        return values
    }

    private static func stableOrder(
        _ lhs: TimelineEvent,
        _ rhs: TimelineEvent
    ) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }
        if lhs.kind.stablePriority != rhs.kind.stablePriority {
            return lhs.kind.stablePriority < rhs.kind.stablePriority
        }
        if lhs.sourceID != rhs.sourceID {
            return lhs.sourceID.uuidString < rhs.sourceID.uuidString
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private static func doseText(_ medication: Medication) -> String {
        guard let value = medication.doseValue else {
            return Copy.Timeline.doseNotRecorded
        }
        let number = value.rounded() == value
            ? String(Int(value))
            : String(format: "%.2f", value)
                .replacingOccurrences(
                    of: #"0+$"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\.$"#,
                    with: "",
                    options: .regularExpression
                )
        return number + medication.doseUnit
    }
}

@MainActor
struct TimelineRepository {
    let context: ModelContext

    func page(
        patientID: UUID,
        filter: TimelineFilter,
        request: TimelinePageRequest,
        now: Date
    ) throws -> TimelinePage {
        let requestedEnd = min(
            request.offset + request.limit,
            TimelineQueryPolicy.maximumTimelineEvents
        )
        guard request.offset < TimelineQueryPolicy.maximumTimelineEvents else {
            return TimelinePage(events: [], hasMore: false)
        }
        let sourceLimit = min(
            max(requestedEnd + 1, TimelineQueryPolicy.defaultPageSize),
            TimelineQueryPolicy.maximumSourceRows
        )

        let recordLimit = filter == .abnormal
            ? TimelineQueryPolicy.maximumSourceRows
            : sourceLimit
        let records = try fetchRecords(
            patientID: patientID,
            limit: recordLimit,
            enabled: filter != .medications && filter != .followUps
        )
        let medications = try fetchMedications(
            patientID: patientID,
            enabled: filter == .all || filter == .medications
        )
        let orders = try fetchOrders(
            patientID: patientID,
            limit: sourceLimit,
            enabled: filter == .all || filter == .followUps
        )
        let followUps = try fetchFollowUps(
            patientID: patientID,
            enabled: filter == .all || filter == .followUps
        )

        let merged = TimelineBuilder.apply(
            filter,
            to: TimelineBuilder.build(
                patientID: patientID,
                records: records,
                medications: medications,
                orders: orders,
                followUps: followUps,
                now: now
            )
        )
        let pageValues = Array(
            merged.dropFirst(request.offset).prefix(request.limit)
        )
        let sourceMayHaveMore = (
            recordLimit < TimelineQueryPolicy.maximumSourceRows
                && records.count == recordLimit
        ) || (
            sourceLimit < TimelineQueryPolicy.maximumSourceRows
                && orders.count == sourceLimit
        )
        let hasMore = requestedEnd < TimelineQueryPolicy.maximumTimelineEvents
            && (merged.count > requestedEnd || sourceMayHaveMore)
        return TimelinePage(events: pageValues, hasMore: hasMore)
    }

    private func fetchRecords(
        patientID: UUID,
        limit: Int,
        enabled: Bool
    ) throws -> [MedicalRecord] {
        guard enabled else { return [] }
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [
                SortDescriptor(\.eventDate, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    private func fetchMedications(
        patientID: UUID,
        enabled: Bool
    ) throws -> [Medication] {
        guard enabled else { return [] }
        var descriptor = FetchDescriptor<Medication>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [
                SortDescriptor(\.startDate, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = TimelineQueryPolicy.maximumSourceRows
        return try context.fetch(descriptor)
    }

    private func fetchOrders(
        patientID: UUID,
        limit: Int,
        enabled: Bool
    ) throws -> [MedicalOrder] {
        guard enabled else { return [] }
        var descriptor = FetchDescriptor<MedicalOrder>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    private func fetchFollowUps(
        patientID: UUID,
        enabled: Bool
    ) throws -> [FollowUp] {
        guard enabled else { return [] }
        var descriptor = FetchDescriptor<FollowUp>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [
                SortDescriptor(\.plannedDate, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = TimelineQueryPolicy.maximumSourceRows
        return try context.fetch(descriptor)
    }
}
