import Foundation
import SwiftUI

enum ElderFontScale: String, CaseIterable, Identifiable, Codable {
    case standard
    case larger
    case largest

    static let storageKey = "carethread.elderFontScale"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "标准"
        case .larger: "更大"
        case .largest: "最大"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .standard: 1
        case .larger: 1.08
        case .largest: 1.16
        }
    }
}

struct ElderTypographyValues: Equatable {
    let display: CGFloat
    let title2: CGFloat
    let headline: CGFloat
    let body: CGFloat
    let subhead: CGFloat
    let footnote: CGFloat
    let valueBig: CGFloat
    let primaryButtonHeight: CGFloat
    let listRowHeight: CGFloat
    let touchTarget: CGFloat

    static func resolve(
        mode: DisplayMode,
        elderScale: ElderFontScale = .standard
    ) -> ElderTypographyValues {
        guard mode == .elder else {
            return ElderTypographyValues(
                display: 34,
                title2: 22,
                headline: 17,
                body: 17,
                subhead: 15,
                footnote: 13,
                valueBig: 22,
                primaryButtonHeight: CT.Size.primaryButtonHeight,
                listRowHeight: CT.Size.listRowHeight,
                touchTarget: CT.Size.secondaryButtonHeight
            )
        }
        let scale = elderScale.multiplier
        return ElderTypographyValues(
            display: 40 * scale,
            title2: 28 * scale,
            headline: 22 * scale,
            body: 20 * scale,
            subhead: 18 * scale,
            footnote: 16 * scale,
            valueBig: 34 * scale,
            primaryButtonHeight: CT.Size.elderPrimaryButtonHeight,
            listRowHeight: CT.Size.elderListRowHeight,
            touchTarget: CT.Size.elderTouchTarget
        )
    }
}

enum ElderDynamicTypePolicy {
    static let maximum = DynamicTypeSize.accessibility2

    static func capped(_ requested: DynamicTypeSize) -> DynamicTypeSize {
        requested > maximum ? maximum : requested
    }
}

struct ElderDisplayModeStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var storedMode: DisplayMode {
        get {
            defaults.string(forKey: DisplayMode.storageKey)
                .flatMap(DisplayMode.init(rawValue:)) ?? .standard
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: DisplayMode.storageKey)
        }
    }

    func effectiveMode(launchOverride: DisplayMode?) -> DisplayMode {
        launchOverride ?? storedMode
    }
}

enum ElderCaptureTypeChoice: String, CaseIterable, Identifiable, Codable {
    case lab
    case examination
    case outpatient
    case discharge
    case prescription
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lab: "化验单"
        case .examination: "检查报告"
        case .outpatient: "病历"
        case .discharge: "出院小结"
        case .prescription: "药单处方"
        case .other: "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .lab: "testtube.2"
        case .examination: "waveform.path.ecg.rectangle"
        case .outpatient: "stethoscope"
        case .discharge: "bed.double"
        case .prescription: "pills"
        case .other: "doc"
        }
    }
}

enum ElderCaptureTypePolicy {
    static func resolvedType(
        choice: ElderCaptureTypeChoice,
        machineType: RecordType
    ) -> RecordType {
        switch choice {
        case .lab:
            return .lab
        case .examination:
            return [.imaging, .pathology].contains(machineType)
                ? machineType
                : .imaging
        case .outpatient:
            return .outpatient
        case .discharge:
            return .discharge
        case .prescription:
            return .prescription
        case .other:
            return machineType == .other ? .other : machineType
        }
    }
}

enum ElderDraftVisibilityPolicy {
    static func shouldShowStandardDraftResume(in mode: DisplayMode) -> Bool {
        mode == .standard
    }
}

struct ElderNotificationContent: Equatable {
    let title: String
    let body: String
}

enum ElderNotificationCopyBuilder {
    static func medication(
        name: String,
        dose: String,
        usage: String
    ) -> ElderNotificationContent {
        let detail = [dose, usage]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "（")
        let suffix = usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? detail
            : "\(detail)）"
        return ElderNotificationContent(
            title: "该吃药了",
            body: "该吃药了：\(name)\(suffix.isEmpty ? "" : " \(suffix)")"
        )
    }

    static func followUp(item: String) -> ElderNotificationContent {
        ElderNotificationContent(
            title: "明天要复查了",
            body: "明天要复查了：\(item)，记得带上旧报告"
        )
    }
}

enum ElderNotificationDestinationPolicy {
    enum Destination: Equatable {
        case standardRoute
        case elderToday
    }

    static func destination(for mode: DisplayMode) -> Destination {
        mode == .elder ? .elderToday : .standardRoute
    }
}
