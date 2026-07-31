import SwiftUI
import Testing
@testable import CareThread

struct AppearanceModeTests {
    @Test("外观主题三档映射明确且默认跟随系统")
    func threeModesMapToColorSchemes() {
        #expect(AppearanceMode.allCases == [.system, .light, .dark])
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
        #expect(AppearanceMode.storageKey == "appearanceMode")
    }

    @Test("截图外观覆盖只影响本次解析且不改持久值")
    func launchOverrideIsNonPersistent() {
        let stored = AppearanceMode.dark.rawValue
        #expect(
            AppearanceMode.parseLaunchOverride(
                arguments: [
                    "CareThread",
                    "-screenshotAppearance",
                    "light"
                ]
            ) == .light
        )
        #expect(
            AppearanceMode.effective(
                storedRawValue: stored,
                arguments: [
                    "CareThread",
                    "-screenshotAppearance",
                    "light"
                ]
            ) == .light
        )
        #expect(stored == AppearanceMode.dark.rawValue)
        #expect(
            AppearanceMode.effective(
                storedRawValue: stored,
                arguments: ["CareThread"]
            ) == .dark
        )
        #expect(
            AppearanceMode.effective(
                storedRawValue: stored,
                arguments: [
                    "CareThread",
                    "-screenshotAppearance",
                    "invalid"
                ]
            ) == .dark
        )
    }
}
