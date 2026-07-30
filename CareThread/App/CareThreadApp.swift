import SwiftUI
import SwiftData

@main
struct CareThreadApp: App {
    private let databaseState: DatabaseBootstrapState
    private let skipsStartupRecovery: Bool

    init() {
        #if DEBUG
        let isUITest = ProcessInfo.processInfo.arguments.contains("-uiTestMode")
        let uiTestContainer = isUITest
            ? try? DatabaseBootstrapper.defaultBuilder(mode: .recoveryMemory)
            : nil
        #else
        let isUITest = false
        let uiTestContainer: ModelContainer? = nil
        #endif
        let bootstrapped = uiTestContainer.map(DatabaseBootstrapState.ready)
            ?? DatabaseBootstrapper.bootstrap()
        databaseState = bootstrapped
        skipsStartupRecovery = isUITest
    }

    var body: some Scene {
        WindowGroup {
            switch databaseState {
            case let .ready(container):
                StartupRecoveryGate(
                    container: container,
                    skipsRecovery: skipsStartupRecovery
                ) {
                    AppLockGate {
                        #if DEBUG
                        if let route = ScreenshotRoute.current {
                            ScreenshotRouteView(route: route)
                        } else {
                            RootView()
                        }
                        #else
                        RootView()
                        #endif
                    }
                }
                .modelContainer(container)
            case let .recovery(info, container?):
                DatabaseRecoveryView(info: info)
                    .modelContainer(container)
            case let .recovery(info, nil):
                DatabaseRecoveryView(info: info)
            }
        }
    }
}

private struct StartupRecoveryGate<Content: View>: View {
    private enum Phase {
        case recovering
        case ready
        case failed(DatabaseRecoveryInfo)
    }

    let container: ModelContainer
    let skipsRecovery: Bool
    @ViewBuilder let content: () -> Content
    @State private var phase: Phase

    init(
        container: ModelContainer,
        skipsRecovery: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.container = container
        self.skipsRecovery = skipsRecovery
        self.content = content
        _phase = State(initialValue: skipsRecovery ? .ready : .recovering)
    }

    var body: some View {
        Group {
            switch phase {
            case .recovering:
                ProgressView(Copy.Recovery.progress)
                    .accessibilityIdentifier("startup-recovery-progress")
            case .ready:
                content()
            case let .failed(info):
                DatabaseRecoveryView(info: info)
            }
        }
        .task {
            guard !skipsRecovery else { return }
            guard case .recovering = phase else { return }
            do {
                let vault = try CaptureVaultService()
                try await BackupImporter(
                    context: container.mainContext,
                    vault: vault
                ).recoverInterruptedRestoreIfNeeded()
                try Task.checkCancellation()
                try vault.reconcilePendingFinalizations(
                    context: container.mainContext
                )
                phase = .ready
            } catch is CancellationError {
                return
            } catch {
                AppLog.vault.error(
                    "Vault transaction reconciliation failed; entered protected recovery"
                )
                phase = .failed(
                    DatabaseRecoveryInfo(
                        referenceCode: "VAULT-0001",
                        userMessage: Copy.Recovery.vaultFailure
                    )
                )
            }
        }
    }
}
