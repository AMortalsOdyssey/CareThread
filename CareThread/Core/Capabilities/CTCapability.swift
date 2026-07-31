import Foundation

/// The single version/device capability gate for optional enhancements.
///
/// Feature code asks for a semantic capability and must always keep a complete
/// baseline path. OS-version checks and device eligibility do not belong in
/// feature views or services.
enum CTCapability {
    enum Feature: CaseIterable {
        case deviceLanguageModelRewrite
        case interactiveSystemActions
        case modernVisionInterface
        case systemSearchPlacement
    }

    struct Environment: Equatable {
        let operatingSystemMajorVersion: Int
        let supportsDeviceLanguageModel: Bool

        static var current: Environment {
            Environment(
                operatingSystemMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion,
                // The phase-one baseline never assumes Apple Intelligence is
                // available. A future FoundationModels adapter supplies the
                // device-specific value after checking the framework.
                supportsDeviceLanguageModel: false
            )
        }
    }

    static func isAvailable(
        _ feature: Feature,
        environment: Environment = .current
    ) -> Bool {
        switch feature {
        case .deviceLanguageModelRewrite:
            return environment.operatingSystemMajorVersion >= 26
                && environment.supportsDeviceLanguageModel
        case .interactiveSystemActions:
            return environment.operatingSystemMajorVersion >= 18
        case .modernVisionInterface:
            return environment.operatingSystemMajorVersion >= 18
        case .systemSearchPlacement:
            return environment.operatingSystemMajorVersion >= 26
        }
    }
}
