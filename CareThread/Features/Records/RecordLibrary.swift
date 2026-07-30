import Foundation
import SwiftData
import SwiftUI

enum M3RecordSort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: Copy.Records.newestFirst
        case .oldest: Copy.Records.oldestFirst
        case .title: Copy.Records.titleSort
        }
    }
}

struct M3RecordFilter: Equatable {
    var startDate: Date?
    var endDate: Date?
    var typeRawValues: Set<String> = []
    var diseaseValues: Set<String> = []
    var hospitalValues: Set<String> = []
    var doctorValues: Set<String> = []
    var minimumAge: Int?
    var maximumAge: Int?
    var pendingReviewOnly = false
    var sort: M3RecordSort = .newest

    var isEmpty: Bool {
        startDate == nil
            && endDate == nil
            && typeRawValues.isEmpty
            && diseaseValues.isEmpty
            && hospitalValues.isEmpty
            && doctorValues.isEmpty
            && minimumAge == nil
            && maximumAge == nil
            && !pendingReviewOnly
    }

    var signature: String {
        let dates = [
            startDate.map { String(describing: $0) } ?? "",
            endDate.map { String(describing: $0) } ?? ""
        ]
        let selections = [
            typeRawValues.sorted().joined(separator: ","),
            diseaseValues.sorted().joined(separator: ","),
            hospitalValues.sorted().joined(separator: ","),
            doctorValues.sorted().joined(separator: ",")
        ]
        let ages = [
            minimumAge.map(String.init) ?? "",
            maximumAge.map(String.init) ?? ""
        ]
        return (
            dates + selections + ages
                + [pendingReviewOnly ? "pending" : "all", sort.rawValue]
        ).joined(separator: "|")
    }
}

struct M3RecordCursor: Equatable {
    let patientID: UUID
    let filterSignature: String
    let searchSignature: String
    let sort: M3RecordSort
    let generation: Int
    /// The first page freezes membership to rows whose immutable `createdAt`
    /// is no later than this bound. Normal later inserts are part of the next
    /// reload; rows deleted during paging disappear from the live snapshot.
    let snapshotCreatedAtUpperBound: Date
    let lastTitleSortKey: String
    let lastEventDate: Date
    let lastCreatedAt: Date
    let lastID: UUID
}

struct M3RecordPage {
    let records: [MedicalRecord]
    let nextCursor: M3RecordCursor?
}

struct M3RecordFacets {
    var hospitals: [String]
    var doctors: [String]
    var diseases: [String]
    var pendingReviewCount: Int
}

@MainActor
enum M3RecordLibraryService {
    static let pageSize = 30
    static let scanBatchSize = 120

    static func page(
        context: ModelContext,
        patientID: UUID,
        searchText: String,
        filter: M3RecordFilter,
        generation: Int,
        after cursor: M3RecordCursor?
    ) throws -> M3RecordPage {
        let searchSignature = MemberIdentity.normalize(searchText)
        if let cursor {
            guard cursor.patientID == patientID,
                  cursor.filterSignature == filter.signature,
                  cursor.searchSignature == searchSignature,
                  cursor.sort == filter.sort,
                  cursor.generation == generation else {
                return M3RecordPage(records: [], nextCursor: nil)
            }
        }

        var values: [MedicalRecord] = []
        var scanCursor = cursor
        let snapshotCreatedAtUpperBound = try cursor?.snapshotCreatedAtUpperBound
            ?? snapshotUpperBound(context: context, patientID: patientID)
        var hasPotentialMore = true
        while values.count < pageSize, hasPotentialMore {
            let batch = try fetchBatch(
                context: context,
                patientID: patientID,
                sort: filter.sort,
                snapshotCreatedAtUpperBound: snapshotCreatedAtUpperBound,
                after: scanCursor
            )
            guard !batch.isEmpty else {
                hasPotentialMore = false
                break
            }
            var consumedFromBatch = 0
            for record in batch.prefix(scanBatchSize) {
                consumedFromBatch += 1
                scanCursor = makeCursor(
                    record: record,
                    patientID: patientID,
                    searchSignature: searchSignature,
                    filter: filter,
                    generation: generation,
                    snapshotCreatedAtUpperBound: snapshotCreatedAtUpperBound
                )
                if matches(record, searchText: searchText, filter: filter) {
                    values.append(record)
                    if values.count == pageSize { break }
                }
            }
            // fetchBatch asks for one look-ahead row. If the current page
            // stopped early or that look-ahead exists, the seek key can
            // continue without relying on a mutable row offset.
            hasPotentialMore = consumedFromBatch < batch.count
        }
        let next = hasPotentialMore ? scanCursor : nil
        return M3RecordPage(records: values, nextCursor: next)
    }

    static func facets(
        context: ModelContext,
        patientID: UUID
    ) throws -> M3RecordFacets {
        var hospitals = Set<String>()
        var doctors = Set<String>()
        var diseases = Set<String>()
        var pendingReviewCount = 0
        let snapshotCreatedAtUpperBound = try snapshotUpperBound(
            context: context,
            patientID: patientID
        )
        var cursor: M3RecordCursor?
        while true {
            let batch = try fetchBatch(
                context: context,
                patientID: patientID,
                sort: .newest,
                snapshotCreatedAtUpperBound: snapshotCreatedAtUpperBound,
                after: cursor
            )
            guard !batch.isEmpty else { break }
            let scanned = Array(batch.prefix(scanBatchSize))
            for record in scanned {
                if record.reviewStatus == .pending {
                    pendingReviewCount += 1
                }
                if let hospital = record.hospital { hospitals.insert(hospital) }
                if let doctor = record.doctor { doctors.insert(doctor) }
                [record.primaryDisease].compactMap { $0 }.forEach { diseases.insert($0) }
                record.diseaseTags.forEach { diseases.insert($0) }
            }
            guard let last = scanned.last else { break }
            cursor = makeCursor(
                record: last,
                patientID: patientID,
                searchSignature: "",
                filter: M3RecordFilter(),
                generation: 0,
                snapshotCreatedAtUpperBound: snapshotCreatedAtUpperBound
            )
            if batch.count <= scanBatchSize { break }
        }
        return M3RecordFacets(
            hospitals: hospitals.sorted(),
            doctors: doctors.sorted(),
            diseases: diseases.sorted(),
            pendingReviewCount: pendingReviewCount
        )
    }

    private static func fetchBatch(
        context: ModelContext,
        patientID: UUID,
        sort: M3RecordSort,
        snapshotCreatedAtUpperBound: Date,
        after cursor: M3RecordCursor?
    ) throws -> [MedicalRecord] {
        let descriptor: FetchDescriptor<MedicalRecord>
        switch sort {
        case .newest:
            if let cursor {
                let eventDate = cursor.lastEventDate
                let createdAt = cursor.lastCreatedAt
                let id = cursor.lastID
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.patientId == patientID
                            && $0.createdAt <= snapshotCreatedAtUpperBound
                            && (
                                $0.eventDate < eventDate
                                    || (
                                        $0.eventDate == eventDate
                                            && $0.createdAt < createdAt
                                    )
                                    || (
                                        $0.eventDate == eventDate
                                            && $0.createdAt == createdAt
                                            && $0.id < id
                                    )
                            )
                    },
                    sortBy: newestSort
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.patientId == patientID
                            && $0.createdAt <= snapshotCreatedAtUpperBound
                    },
                    sortBy: newestSort
                )
            }
        case .oldest:
            if let cursor {
                let eventDate = cursor.lastEventDate
                let createdAt = cursor.lastCreatedAt
                let id = cursor.lastID
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.patientId == patientID
                            && $0.createdAt <= snapshotCreatedAtUpperBound
                            && (
                                $0.eventDate > eventDate
                                    || (
                                        $0.eventDate == eventDate
                                            && $0.createdAt > createdAt
                                    )
                                    || (
                                        $0.eventDate == eventDate
                                            && $0.createdAt == createdAt
                                            && $0.id > id
                                    )
                            )
                    },
                    sortBy: oldestSort
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.patientId == patientID
                            && $0.createdAt <= snapshotCreatedAtUpperBound
                    },
                    sortBy: oldestSort
                )
            }
        case .title:
            if let cursor {
                let titleSortKey = cursor.lastTitleSortKey
                let eventDate = cursor.lastEventDate
                let createdAt = cursor.lastCreatedAt
                let id = cursor.lastID
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.patientId == patientID
                            && $0.createdAt <= snapshotCreatedAtUpperBound
                            && (
                                $0.titleSortKey > titleSortKey
                                    || (
                                        $0.titleSortKey == titleSortKey
                                            && $0.eventDate < eventDate
                                    )
                                    || (
                                        $0.titleSortKey == titleSortKey
                                            && $0.eventDate == eventDate
                                            && $0.createdAt < createdAt
                                    )
                                    || (
                                        $0.titleSortKey == titleSortKey
                                            && $0.eventDate == eventDate
                                            && $0.createdAt == createdAt
                                            && $0.id < id
                                    )
                            )
                    },
                    sortBy: titleSort
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.patientId == patientID
                            && $0.createdAt <= snapshotCreatedAtUpperBound
                    },
                    sortBy: titleSort
                )
            }
        }
        var bounded = descriptor
        bounded.fetchLimit = scanBatchSize + 1
        return try context.fetch(bounded)
    }

    private static let newestSort = [
        SortDescriptor(\MedicalRecord.eventDate, order: .reverse),
        SortDescriptor(\MedicalRecord.createdAt, order: .reverse),
        SortDescriptor(\MedicalRecord.id, order: .reverse)
    ]

    private static let oldestSort = [
        SortDescriptor(\MedicalRecord.eventDate),
        SortDescriptor(\MedicalRecord.createdAt),
        SortDescriptor(\MedicalRecord.id)
    ]

    private static let titleSort = [
        // The seek predicate uses String's lexical comparison. Foundation's
        // default String comparator is localizedStandard (including numeric
        // collation), so it must be made explicit here or ORDER BY and `>`
        // can disagree at a page boundary.
        SortDescriptor(\MedicalRecord.titleSortKey, comparator: .lexical),
        SortDescriptor(\MedicalRecord.eventDate, order: .reverse),
        SortDescriptor(\MedicalRecord.createdAt, order: .reverse),
        SortDescriptor(\MedicalRecord.id, order: .reverse)
    ]

    /// Existing data can legitimately carry a future imported `createdAt`
    /// timestamp (for example a restored backup or deterministic fixture).
    /// Include that data while retaining a monotonic boundary for ordinary
    /// records created after the first page.
    private static func snapshotUpperBound(
        context: ModelContext,
        patientID: UUID
    ) throws -> Date {
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.id, order: .reverse)
            ]
        )
        descriptor.fetchLimit = 1
        guard let maximumExisting = try context.fetch(descriptor).first?.createdAt else {
            return Date()
        }
        return max(Date(), maximumExisting)
    }

    private static func makeCursor(
        record: MedicalRecord,
        patientID: UUID,
        searchSignature: String,
        filter: M3RecordFilter,
        generation: Int,
        snapshotCreatedAtUpperBound: Date
    ) -> M3RecordCursor {
        M3RecordCursor(
            patientID: patientID,
            filterSignature: filter.signature,
            searchSignature: searchSignature,
            sort: filter.sort,
            generation: generation,
            snapshotCreatedAtUpperBound: snapshotCreatedAtUpperBound,
            lastTitleSortKey: record.titleSortKey,
            lastEventDate: record.eventDate,
            lastCreatedAt: record.createdAt,
            lastID: record.id
        )
    }

    private static func matches(
        _ record: MedicalRecord,
        searchText: String,
        filter: M3RecordFilter
    ) -> Bool {
        if let startDate = filter.startDate, record.eventDate < startDate {
            return false
        }
        if let endDate = filter.endDate, record.eventDate > endDate {
            return false
        }
        if !filter.typeRawValues.isEmpty,
           !filter.typeRawValues.contains(record.type.rawValue) {
            return false
        }
        if !filter.diseaseValues.isEmpty {
            let diseases = Set(
                ([record.primaryDisease].compactMap { $0 } + record.diseaseTags)
                    .map(MemberIdentity.normalize)
            )
            let requested = Set(filter.diseaseValues.map(MemberIdentity.normalize))
            if diseases.isDisjoint(with: requested) { return false }
        }
        if !filter.hospitalValues.isEmpty,
           !filter.hospitalValues.contains(record.hospital ?? "") {
            return false
        }
        if !filter.doctorValues.isEmpty,
           !filter.doctorValues.contains(record.doctor ?? "") {
            return false
        }
        if let minimumAge = filter.minimumAge,
           (record.ageAtEvent ?? Int.min) < minimumAge {
            return false
        }
        if let maximumAge = filter.maximumAge,
           (record.ageAtEvent ?? Int.max) > maximumAge {
            return false
        }
        if filter.pendingReviewOnly, record.reviewStatus != .pending {
            return false
        }
        let query = MemberIdentity.normalize(searchText)
        if !query.isEmpty {
            let searchable = MemberIdentity.normalize(
                [
                    record.displayTitle,
                    record.summary,
                    record.hospital,
                    record.department,
                    record.doctor,
                    record.primaryDisease,
                    record.ocrText
                ]
                .compactMap { $0 }
                .joined(separator: " ")
            )
            if !searchable.contains(query) { return false }
        }
        return true
    }
}

@MainActor
final class M3RecordLibraryViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published private(set) var records: [MedicalRecord] = []
    @Published private(set) var hasMore = false
    @Published private(set) var state: LoadState = .idle
    @Published var filter = M3RecordFilter()
    @Published var searchText = ""
    @Published private(set) var allHospitals: [String] = []
    @Published private(set) var allDoctors: [String] = []
    @Published private(set) var allDiseases: [String] = []
    @Published private(set) var pendingReviewCount = 0

    private var context: ModelContext?
    private var patientID: UUID?
    private var generation = 0
    private var cursor: M3RecordCursor?
    private var loadTask: Task<Void, Never>?

    var availableHospitals: [String] {
        allHospitals
    }

    var availableDoctors: [String] {
        allDoctors
    }

    var availableDiseases: [String] {
        allDiseases
    }

    func configure(context: ModelContext) {
        self.context = context
    }

    func reload(patientID: UUID?) {
        generation += 1
        loadTask?.cancel()
        self.patientID = patientID
        cursor = nil
        records = []
        hasMore = false
        pendingReviewCount = 0
        guard let patientID, let context else {
            state = .loaded
            return
        }
        let requestGeneration = generation
        state = .loading
        loadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.generation == requestGeneration else { return }
            do {
                let facets = try M3RecordLibraryService.facets(
                    context: context,
                    patientID: patientID
                )
                let page = try M3RecordLibraryService.page(
                    context: context,
                    patientID: patientID,
                    searchText: searchText,
                    filter: filter,
                    generation: requestGeneration,
                    after: nil
                )
                guard self.generation == requestGeneration else { return }
                allHospitals = facets.hospitals
                allDoctors = facets.doctors
                allDiseases = facets.diseases
                pendingReviewCount = facets.pendingReviewCount
                records = page.records
                cursor = page.nextCursor
                hasMore = page.nextCursor != nil
                state = .loaded
            } catch {
                guard self.generation == requestGeneration else { return }
                state = .failed
            }
        }
    }

    func loadMore() {
        guard hasMore, let cursor, let context, let patientID else { return }
        let requestGeneration = generation
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.generation == requestGeneration else { return }
            do {
                let page = try M3RecordLibraryService.page(
                    context: context,
                    patientID: patientID,
                    searchText: searchText,
                    filter: filter,
                    generation: requestGeneration,
                    after: cursor
                )
                guard self.generation == requestGeneration else { return }
                records.append(contentsOf: page.records)
                self.cursor = page.nextCursor
                hasMore = page.nextCursor != nil
            } catch {
                state = .failed
            }
        }
    }

    func showPendingInbox(patientID: UUID?) {
        searchText = ""
        filter = M3RecordFilter(pendingReviewOnly: true)
        reload(patientID: patientID)
    }

    func clearPendingInbox(patientID: UUID?) {
        searchText = ""
        filter = M3RecordFilter()
        reload(patientID: patientID)
    }
}
