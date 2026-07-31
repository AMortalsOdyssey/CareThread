import Testing
@testable import CareThread

struct CTCapabilityTests {
    @Test("系统增强能力在门槛满足时可用")
    func availableCapabilities() {
        let iOS18 = CTCapability.Environment(
            operatingSystemMajorVersion: 18,
            supportsDeviceLanguageModel: false
        )
        let iOS26 = CTCapability.Environment(
            operatingSystemMajorVersion: 26,
            supportsDeviceLanguageModel: true
        )

        #expect(CTCapability.isAvailable(.interactiveSystemActions, environment: iOS18))
        #expect(CTCapability.isAvailable(.modernVisionInterface, environment: iOS18))
        #expect(CTCapability.isAvailable(.systemSearchPlacement, environment: iOS26))
        #expect(CTCapability.isAvailable(.deviceLanguageModelRewrite, environment: iOS26))
    }

    @Test("旧系统或设备不支持时保持完整基线")
    func unavailableCapabilities() {
        let iOS17 = CTCapability.Environment(
            operatingSystemMajorVersion: 17,
            supportsDeviceLanguageModel: false
        )
        let unsupportedDevice = CTCapability.Environment(
            operatingSystemMajorVersion: 26,
            supportsDeviceLanguageModel: false
        )

        for feature in CTCapability.Feature.allCases {
            #expect(!CTCapability.isAvailable(feature, environment: iOS17))
        }
        #expect(
            !CTCapability.isAvailable(
                .deviceLanguageModelRewrite,
                environment: unsupportedDevice
            )
        )
    }
}
