import SwiftUI

enum AppearanceMode: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearanceMode"

    static var launchOverride: AppearanceMode? {
        parseLaunchOverride(arguments: ProcessInfo.processInfo.arguments)
    }

    static func parseLaunchOverride(
        arguments: [String]
    ) -> AppearanceMode? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-screenshotAppearance"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return AppearanceMode(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }

    static func effective(
        storedRawValue: String,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppearanceMode {
        parseLaunchOverride(arguments: arguments)
            ?? AppearanceMode(rawValue: storedRawValue)
            ?? .system
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceMode.storageKey)
    private var storedMode = AppearanceMode.system.rawValue
    var body: some View {
        List {
            Section {
                Picker("外观主题", selection: $storedMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbol)
                            .tag(mode.rawValue)
                            .accessibilityIdentifier(
                                "appearance.option.\(mode.rawValue)"
                            )
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .tint(CT.Color.primary)
            } footer: {
                Text("设置会立即应用，并保存在这台 iPhone 上。")
                    .foregroundStyle(CT.Color.inkSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle("外观主题")
    }
}
