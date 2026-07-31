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
}
