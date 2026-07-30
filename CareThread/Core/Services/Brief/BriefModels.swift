import Foundation

struct BriefMemberSnapshot: Equatable {
    let id: UUID
    let displayName: String
    let birthDate: Date?
    let gender: String?
    let conditions: [String]
    let allergies: [String]
    let histories: [HistoryItem]

    init(
        id: UUID,
        displayName: String,
        birthDate: Date?,
        gender: String? = nil,
        conditions: [String],
        allergies: [String],
        histories: [HistoryItem]
    ) {
        self.id = id
        self.displayName = displayName
        self.birthDate = birthDate
        self.gender = gender
        self.conditions = conditions
        self.allergies = allergies
        self.histories = histories
    }
}

struct BriefMeasurementSnapshot: Equatable {
    let name: String
    let numericValue: Double?
    let textualValue: String?
    let unit: String
    let abnormalState: LabFlag
}

struct BriefTagSnapshot: Equatable {
    let kind: RecordTagKind
    let value: String
}

struct BriefRecordSnapshot: Equatable, Identifiable {
    let id: UUID
    let patientID: UUID
    let eventDate: Date
    let title: String
    let summary: String
    let type: RecordType
    let reviewStatus: ReviewStatus
    let isInBrief: Bool
    let abnormalFlags: [String]
    let structuredFields: [KeyValueItem]
    let measurements: [BriefMeasurementSnapshot]
    let tags: [BriefTagSnapshot]
    let hospital: String?
    let doctor: String?
    let primaryDisease: String?
    let isKeyRecord: Bool

    init(
        id: UUID,
        patientID: UUID,
        eventDate: Date,
        title: String,
        summary: String,
        type: RecordType,
        reviewStatus: ReviewStatus,
        isInBrief: Bool,
        abnormalFlags: [String],
        structuredFields: [KeyValueItem],
        measurements: [BriefMeasurementSnapshot],
        tags: [BriefTagSnapshot],
        hospital: String? = nil,
        doctor: String? = nil,
        primaryDisease: String? = nil,
        isKeyRecord: Bool = false
    ) {
        self.id = id
        self.patientID = patientID
        self.eventDate = eventDate
        self.title = title
        self.summary = summary
        self.type = type
        self.reviewStatus = reviewStatus
        self.isInBrief = isInBrief
        self.abnormalFlags = abnormalFlags
        self.structuredFields = structuredFields
        self.measurements = measurements
        self.tags = tags
        self.hospital = hospital
        self.doctor = doctor
        self.primaryDisease = primaryDisease
        self.isKeyRecord = isKeyRecord
    }

    var isAbnormal: Bool {
        !abnormalFlags.isEmpty
            || measurements.contains { $0.abnormalState != .none }
    }
}

struct BriefMedicationSnapshot: Equatable, Identifiable {
    let id: UUID
    let patientID: UUID
    let name: String
    let doseValue: Double?
    let doseUnit: String
    let frequency: FrequencyPreset
    let weeklyCount: Int?
    let startDate: Date
    let endDate: Date?
    let lifecycleStatus: MedicationLifecycleStatus

    func isCurrent(at date: Date) -> Bool {
        lifecycleStatus == .active
            && startDate <= date
            && (endDate.map { date < $0 } ?? true)
    }
}

struct BriefFollowUpSnapshot: Equatable, Identifiable {
    let id: UUID
    let patientID: UUID
    let plannedDate: Date
    let items: [String]
    let reason: String?
    let status: FollowUpStatus
}

struct BriefInput: Equatable {
    let member: BriefMemberSnapshot
    let records: [BriefRecordSnapshot]
    let medications: [BriefMedicationSnapshot]
    let followUps: [BriefFollowUpSnapshot]
    var questions: [String] = []
}

enum BriefSectionID: String, CaseIterable, Identifiable {
    case basicProfile
    case currentIssues
    case recentKeyResults
    case currentMedications
    case allergiesAndHistory
    case pendingFollowUps
    case selectedRecords
    case questions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basicProfile: "基本档案"
        case .currentIssues: "当前主要问题"
        case .recentKeyResults: "最近异常与关键结果"
        case .currentMedications: "当前用药"
        case .allergiesAndHistory: "过敏史与重要病史"
        case .pendingFollowUps: "待复查"
        case .selectedRecords: "用户选中记录"
        case .questions: "想问医生的问题"
        }
    }
}

struct BriefSelection: Equatable {
    var enabledSections: Set<BriefSectionID> = Set(BriefSectionID.allCases)
    /// nil means use every record explicitly marked `inBrief`.
    var selectedRecordIDs: Set<UUID>? = nil
}

struct BriefItem: Equatable, Identifiable {
    let id: String
    let text: String
    let sourceNumber: Int?
    let sourceRecordID: UUID?

    var sourceMarker: String? {
        sourceNumber.map(BriefSource.marker)
    }
}

struct BriefSection: Equatable, Identifiable {
    let id: BriefSectionID
    let title: String
    let items: [BriefItem]
}

struct BriefSource: Equatable, Identifiable {
    let number: Int
    let recordID: UUID
    let eventDate: Date
    let title: String
    let recordType: RecordType

    var id: UUID { recordID }

    static func marker(_ number: Int) -> String {
        let markers = [
            "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
            "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳"
        ]
        guard number > 0, number <= markers.count else {
            return "[\(number)]"
        }
        return markers[number - 1]
    }
}

struct BriefDocument: Equatable {
    let memberID: UUID
    let memberName: String
    let generatedAt: Date
    let sections: [BriefSection]
    let sources: [BriefSource]
    let disclaimer: String

    /// A profile by itself is not a clinical summary and must not enable
    /// export in the all-empty boundary state.
    var hasExportableContent: Bool {
        sections.contains {
            $0.id != .basicProfile && !$0.items.isEmpty
        }
    }
}

struct RecordExportPayload: Equatable {
    let memberID: UUID
    let memberName: String
    let generatedAt: Date
    let rangeName: String
    let brief: BriefDocument
    let records: [BriefRecordSnapshot]
}

// The payload is an immutable value graph (Foundation value types plus arrays
// of immutable snapshots). It is safe to transfer to the detached PDF renderer.
extension RecordExportPayload: @unchecked Sendable {}
