import Foundation

enum VisitPreparationSectionID:
    String,
    CaseIterable,
    Identifiable,
    Sendable {
    case basicInfo
    case allergies
    case currentMedications
    case conditions
    case careTeam
    case keyRecords
    case questions
    case contact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basicInfo:
            Copy.VisitPreparation.sectionBasicInfo
        case .allergies:
            Copy.VisitPreparation.sectionAllergies
        case .currentMedications:
            Copy.VisitPreparation.sectionMedications
        case .conditions:
            Copy.VisitPreparation.sectionConditions
        case .careTeam:
            Copy.VisitPreparation.sectionCareTeam
        case .keyRecords:
            Copy.VisitPreparation.sectionKeyRecords
        case .questions:
            Copy.VisitPreparation.sectionQuestions
        case .contact:
            Copy.VisitPreparation.sectionContact
        }
    }
}

struct VisitPreparationSelection: Equatable {
    var enabledSections = Set(VisitPreparationSectionID.allCases)
    /// `nil` uses records already marked important or included in the
    /// full brief. An explicit empty set intentionally shows no records.
    var selectedRecordIDs: Set<UUID>? = nil
}

struct VisitPreparationCardItem: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
}

struct VisitPreparationCardSection: Equatable, Identifiable, Sendable {
    let id: VisitPreparationSectionID
    let title: String
    let items: [VisitPreparationCardItem]
}

struct VisitPreparationCardDocument: Equatable, Sendable {
    let memberID: UUID
    let memberName: String
    let generatedAt: Date
    let sections: [VisitPreparationCardSection]
    let omittedItemCount: Int
    let shortenedItemCount: Int
    let disclaimer: String

    var itemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    /// A name alone is not enough to make a useful visit-preparation card.
    var hasExportableContent: Bool {
        sections.contains { section in
            section.id != .basicInfo && !section.items.isEmpty
        }
    }
}

enum VisitPreparationCardPolicy {
    /// Worst-case 2-line items plus all eight section headings must leave
    /// room for omission notes, the disclaimer, and compact PDF branding.
    static let maximumVisibleItems = 14
    static let maximumItemCharacters = 96

    static func itemLimit(for section: VisitPreparationSectionID) -> Int {
        switch section {
        case .basicInfo: 3
        case .allergies: 3
        case .currentMedications: 4
        case .conditions: 4
        case .careTeam: 3
        case .keyRecords: 4
        case .questions: 4
        case .contact: 1
        }
    }
}
