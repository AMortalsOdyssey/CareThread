#if DEBUG
import SwiftUI

/// Describes deterministic navigation into the production Root/Tab shell.
///
/// No route constructs a feature view. `StandardRootTabView` and
/// `ElderRootView` consume this plan by setting their real tab, navigation,
/// sheet, or full-screen state.
enum ScreenshotRoute: String, CaseIterable {
    case onboarding
    case home
    case captureSource = "capture-source"
    case captureConfirmation = "capture-confirmation"
    case records
    case recordDetail = "record-detail"
    case originalOCR = "original-ocr"
    case medications
    case followups
    case timeline
    case brief
    case manage
    case backup
    case lock
    case elderToday = "elder-today"
    case elderCaptureQuestion = "elder-capture-question"
    case elderRecords = "elder-records"
    case elderBrief = "elder-brief"
    case memberManagement = "member-management"
    case comparison
    case export
    case nearbySync = "nearby-sync"
    case more

    static var current: ScreenshotRoute? {
        parse(arguments: ProcessInfo.processInfo.arguments)
    }

    static func parse(arguments: [String]) -> ScreenshotRoute? {
        guard let index = arguments.firstIndex(of: "-screenshotRoute"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return ScreenshotRoute(rawValue: arguments[index + 1])
    }

    var marker: String {
        "screenshot.route.\(rawValue)"
    }

    var isElder: Bool {
        switch self {
        case .elderToday, .elderCaptureQuestion, .elderRecords, .elderBrief:
            true
        default:
            false
        }
    }

    var shell: String {
        switch self {
        case .onboarding:
            "RootView"
        case .lock:
            "AppLockGate"
        default:
            isElder ? "ElderRootView" : "StandardRootTabView"
        }
    }

    var presentation: String {
        switch self {
        case .onboarding:
            "onboarding"
        case .home, .records, .timeline, .manage, .elderToday, .elderRecords:
            "tab"
        case .recordDetail, .medications, .followups, .backup, .memberManagement:
            "push"
        case .captureSource, .captureConfirmation, .brief, .elderCaptureQuestion,
             .elderBrief, .comparison, .export, .nearbySync, .more:
            "sheet"
        case .originalOCR:
            "fullScreen"
        case .lock:
            "gate"
        }
    }

    var selectedTab: Int? {
        switch self {
        case .onboarding, .lock:
            nil
        case .home, .captureSource, .captureConfirmation, .brief, .comparison,
             .export, .nearbySync, .more, .elderToday, .elderCaptureQuestion,
             .elderBrief:
            0
        case .timeline:
            1
        case .records, .recordDetail, .originalOCR:
            3
        case .medications, .followups, .manage, .backup, .memberManagement:
            4
        case .elderRecords:
            2
        }
    }

    var tabBarExpected: Bool {
        presentation == "tab" || presentation == "push"
    }

    var featureMarker: String {
        switch self {
        case .onboarding: "onboarding.localPrivacy"
        case .home: "m45.home"
        case .captureSource: "m3.capture.host"
        case .captureConfirmation: "m3.confirmation"
        case .records: "m3.records.library"
        case .recordDetail: "m3.detail"
        case .originalOCR: "m3.viewer"
        case .medications: "m45.medication.list"
        case .followups: "m45.followup.list"
        case .timeline: "m6.timeline"
        case .brief, .export: "m7.brief"
        case .manage: "m45.manage"
        case .backup: "m8.backup.screen"
        case .lock: "m8.lock.screen"
        case .elderToday: "elder.today"
        case .elderCaptureQuestion: "elder.capture.typeQuestion"
        case .elderRecords: "elder.records"
        case .elderBrief: "elder.brief"
        case .memberManagement: "member.management"
        case .comparison: "m7.compare"
        case .nearbySync: "nearbySync.root"
        case .more: "m45.more"
        }
    }
}

private struct ScreenshotReadyPayload: Codable {
    let route: String
    let shell: String
    let presentation: String
    let selectedTab: Int?
    let tabBarExpected: Bool
    let featureMarker: String
    let resolvedAppearance: String
}

struct ScreenshotReadyMarker: View {
    @Environment(\.colorScheme) private var colorScheme
    let route: ScreenshotRoute

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(route.marker)
            .accessibilityValue(route.shell)
            .overlay {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(
                        "screenshot.actualAppearance.\(resolvedAppearance)"
                    )
            }
            .task(id: route.rawValue) {
                // Route state is applied before this marker mounts. Let
                // production push/sheet transitions and local loaders settle.
                try? await Task.sleep(for: .milliseconds(900))
                writeReadyPayload()
            }
    }

    private var resolvedAppearance: String {
        colorScheme == .dark ? "dark" : "light"
    }

    private func writeReadyPayload() {
        let payload = ScreenshotReadyPayload(
            route: route.rawValue,
            shell: route.shell,
            presentation: route.presentation,
            selectedTab: route.selectedTab,
            tabBarExpected: route.tabBarExpected,
            featureMarker: route.featureMarker,
            resolvedAppearance: resolvedAppearance
        )
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "carethread-screenshot-ready-\(route.rawValue)"
            )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(payload).write(to: url, options: .atomic)
            AppLog.data.info(
                "Production screenshot route ready: \(route.rawValue, privacy: .private(mask: .hash))"
            )
        } catch {
            AppLog.data.error(
                "Screenshot readiness marker failed; code=SCREENSHOT-READY-0001"
            )
        }
    }
}

extension View {
    /// Publishes readiness only after the real production feature view has
    /// mounted and its semantic loading condition is satisfied.
    @ViewBuilder
    func screenshotReady(
        _ route: ScreenshotRoute,
        when condition: Bool = true
    ) -> some View {
        overlay(alignment: .topLeading) {
            if condition, ScreenshotRoute.current == route {
                ScreenshotReadyMarker(route: route)
            }
        }
    }
}
#endif
