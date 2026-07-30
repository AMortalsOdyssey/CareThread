import SwiftUI

enum DisplayMode: String, CaseIterable, Codable {
    case standard
    case elder

    static let storageKey = "displayMode"

    static var launchOverride: DisplayMode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-displayMode"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return DisplayMode(rawValue: arguments[index + 1])
    }
}

private struct DisplayModeKey: EnvironmentKey {
    static let defaultValue = DisplayMode.standard
}

extension EnvironmentValues {
    var displayMode: DisplayMode {
        get { self[DisplayModeKey.self] }
        set { self[DisplayModeKey.self] = newValue }
    }
}

