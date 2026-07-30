import Foundation

enum RecordType: String, Codable, CaseIterable {
    case imaging
    case lab
    case pathology
    case discharge
    case outpatient
    case prescription
    case other

    var displayName: String {
        switch self {
        case .imaging: "影像报告"
        case .lab: "检验报告"
        case .pathology: "病理报告"
        case .discharge: "出院小结"
        case .outpatient: "门诊病历"
        case .prescription: "处方/医嘱单"
        case .other: "其他"
        }
    }
}

enum SourceType: String, Codable, CaseIterable {
    case camera
    case photo
    case file
    case manual
    case fixture
}

enum ReviewStatus: String, Codable, CaseIterable {
    case pending
    case confirmed
    case needsInfo
}

enum AttachmentKind: String, Codable {
    case image
    case pdf
}

enum FrequencyPreset: String, Codable, CaseIterable {
    case dailyOne
    case dailyTwo
    case dailyThree
    case everyOtherDay
    case weekly
    case asNeeded
}

enum FollowUpStatus: String, Codable {
    case pending
    case completed
}

enum LabFlag: String, Codable {
    case none
    case low
    case high
    case positive
}

enum Confidence: String, Codable {
    case high
    case low
}

struct HistoryItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var year: Int
    var text: String
}

struct KeyValueItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String
}

struct LabItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var value: Double
    var unit: String
    var refLow: Double?
    var refHigh: Double?
    var flag: LabFlag
    var confidence: Confidence = .high
}

struct MedicationHint: Codable, Hashable {
    var name: String
    var doseValue: Double?
    var doseUnit: String?
    var frequencyPerDay: Int?
    var usage: [String]
    var confidence: Confidence
}

struct FollowUpHint: Codable, Hashable {
    var plannedDate: Date?
    var offsetDays: Int?
    var items: [String]
    var rawText: String
    var confidence: Confidence
}

struct ExtractionResult: Codable, Hashable {
    var type: RecordType
    var typeConfidence: Confidence
    var eventDate: Date?
    var eventDateConfidence: Confidence
    var hospital: String?
    var department: String?
    var title: String
    var summary: String
    var labItems: [LabItem]
    var abnormalFlags: [String]
    var structuredFields: [KeyValueItem]
    var medicationHints: [MedicationHint]
    var followUpHints: [FollowUpHint]
    var engineIdentifier: String

    static let empty = ExtractionResult(
        type: .other,
        typeConfidence: .low,
        eventDate: nil,
        eventDateConfidence: .low,
        hospital: nil,
        department: nil,
        title: "",
        summary: "",
        labItems: [],
        abnormalFlags: [],
        structuredFields: [],
        medicationHints: [],
        followUpHints: [],
        engineIdentifier: "none"
    )
}

struct ReminderTime: Codable, Hashable {
    var hour: Int
    var minute: Int
}

