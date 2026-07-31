import Combine
import Foundation
import LocalAuthentication

protocol LocalAuthenticationAdapting {
    var isDeviceOwnerAuthenticationAvailable: Bool { get }
    var isBiometricAuthenticationAvailable: Bool { get }
    func authenticate(reason: String) async throws -> Bool
}

struct SystemLocalAuthenticationAdapter: LocalAuthenticationAdapting {
    var isDeviceOwnerAuthenticationAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        )
    }

    var isBiometricAuthenticationAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
    }

    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = AppLockCopy.cancel
        context.localizedFallbackTitle = AppLockCopy.useDevicePasscode
        return try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }
}

protocol AppLockPreferenceStoring: AnyObject {
    var isEnabled: Bool { get set }
}

final class AppLockPreferenceStore: AppLockPreferenceStoring {
    static let enabledKey = "carethread.appLock.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}

protocol AppLockTransferOfferStoring: AnyObject {
    var hasHandledOffer: Bool { get set }
}

final class AppLockTransferOfferStore: AppLockTransferOfferStoring {
    static let handledKey = "carethread.appLock.transferOfferHandled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasHandledOffer: Bool {
        get { defaults.bool(forKey: Self.handledKey) }
        set { defaults.set(newValue, forKey: Self.handledKey) }
    }
}

enum AppLockTransferOfferPolicy {
    static func shouldOffer(
        isReceiving: Bool,
        isAppLockEnabled: Bool,
        isBiometricAuthenticationAvailable: Bool,
        hasHandledOffer: Bool
    ) -> Bool {
        isReceiving
            && !isAppLockEnabled
            && isBiometricAuthenticationAvailable
            && !hasHandledOffer
    }

    /// Claims the one-time offer before the UI presents it, so duplicate
    /// completion events or an interrupted presentation cannot nag again.
    @MainActor
    static func claimIfNeeded(
        isReceiving: Bool,
        isAppLockEnabled: Bool,
        isBiometricAuthenticationAvailable: Bool,
        store: any AppLockTransferOfferStoring
    ) -> Bool {
        guard shouldOffer(
            isReceiving: isReceiving,
            isAppLockEnabled: isAppLockEnabled,
            isBiometricAuthenticationAvailable:
                isBiometricAuthenticationAvailable,
            hasHandledOffer: store.hasHandledOffer
        ) else {
            return false
        }
        store.hasHandledOffer = true
        return true
    }
}

@MainActor
final class AppLockController: ObservableObject {
    enum Phase: Equatable {
        case disabled
        case locked
        case authenticating
        case unlocked
        case failed
    }

    @Published private(set) var phase: Phase
    private(set) var isEnabled: Bool

    private let authenticator: any LocalAuthenticationAdapting
    private let preferences: any AppLockPreferenceStoring
    private let enabledOverride: Bool?

    init(
        authenticator: any LocalAuthenticationAdapting,
        preferences: any AppLockPreferenceStoring,
        enabledOverride: Bool? = nil
    ) {
        self.authenticator = authenticator
        self.preferences = preferences
        self.enabledOverride = enabledOverride
        let enabled = enabledOverride ?? preferences.isEnabled
        isEnabled = enabled
        phase = enabled ? .locked : .disabled
    }

    var canEnable: Bool {
        authenticator.isDeviceOwnerAuthenticationAvailable
    }

    var canOfferAfterTransfer: Bool {
        authenticator.isBiometricAuthenticationAvailable
    }

    func setEnabled(_ enabled: Bool) async -> Bool {
        if !enabled {
            if enabledOverride == nil { preferences.isEnabled = false }
            isEnabled = false
            phase = .disabled
            AppLog.userAction.info("App lock disabled")
            return true
        }
        guard canEnable else {
            phase = .failed
            AppLog.userAction.warning("App lock enable unavailable")
            return false
        }
        phase = .authenticating
        do {
            guard try await authenticator.authenticate(
                reason: AppLockCopy.enableReason
            ) else {
                phase = .failed
                return false
            }
            if enabledOverride == nil { preferences.isEnabled = true }
            isEnabled = true
            phase = .unlocked
            AppLog.userAction.info("App lock enabled")
            return true
        } catch {
            phase = .failed
            AppLog.userAction.warning("App lock enable authentication failed")
            return false
        }
    }

    func lockForPrivacy() {
        guard isEnabled else {
            phase = .disabled
            return
        }
        phase = .locked
    }

    func unlock() async -> Bool {
        guard isEnabled else {
            phase = .disabled
            return true
        }
        guard phase != .authenticating else { return false }
        phase = .authenticating
        do {
            guard try await authenticator.authenticate(
                reason: AppLockCopy.unlockReason
            ) else {
                phase = .failed
                return false
            }
            phase = .unlocked
            AppLog.userAction.info("App unlocked")
            return true
        } catch {
            phase = .failed
            AppLog.userAction.warning("App unlock authentication failed")
            return false
        }
    }
}

#if DEBUG
final class DebugLocalAuthenticationAdapter: LocalAuthenticationAdapting {
    enum Result {
        case success
        case failure
        case cancelled
    }

    let isDeviceOwnerAuthenticationAvailable: Bool
    let isBiometricAuthenticationAvailable: Bool
    private var results: [Result]

    init(
        available: Bool = true,
        biometricAvailable: Bool? = nil,
        results: [Result] = [.success]
    ) {
        isDeviceOwnerAuthenticationAvailable = available
        isBiometricAuthenticationAvailable = biometricAvailable ?? available
        self.results = results
    }

    func authenticate(reason: String) async throws -> Bool {
        let result = results.isEmpty ? .success : results.removeFirst()
        switch result {
        case .success:
            return true
        case .failure:
            return false
        case .cancelled:
            throw LAError(.userCancel)
        }
    }
}
#endif

enum AppLockRuntime {
    @MainActor
    static func makeController() -> AppLockController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-M8ResetLock") {
            UserDefaults.standard.removeObject(
                forKey: AppLockPreferenceStore.enabledKey
            )
        }
        if arguments.contains("-M8ResetTransferOffer") {
            UserDefaults.standard.removeObject(
                forKey: AppLockTransferOfferStore.handledKey
            )
        }
        let enabled = arguments.contains("-M8LockEnabled") ? true : nil
        if let index = arguments.firstIndex(of: "-M8LockResult"),
           arguments.indices.contains(index + 1) {
            let raw = arguments[index + 1]
            let result: DebugLocalAuthenticationAdapter.Result
            switch raw {
            case "failure": result = .failure
            case "cancelled": result = .cancelled
            default: result = .success
            }
            return AppLockController(
                authenticator: DebugLocalAuthenticationAdapter(
                    available: raw != "unavailable",
                    results: [result, .success]
                ),
                preferences: AppLockPreferenceStore(),
                enabledOverride: enabled
            )
        }
        #endif
        return AppLockController(
            authenticator: SystemLocalAuthenticationAdapter(),
            preferences: AppLockPreferenceStore()
        )
    }
}
