import SwiftUI

struct AppLockGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: AppLockController
    private let content: Content

    @MainActor
    init(
        controller: AppLockController,
        @ViewBuilder content: () -> Content
    ) {
        _controller = StateObject(wrappedValue: controller)
        self.content = content()
    }

    @MainActor
    init(@ViewBuilder content: () -> Content) {
        self.init(
            controller: AppLockRuntime.makeController(),
            content: content
        )
    }

    var body: some View {
        Group {
            if shouldProtect {
                AppLockScreen(controller: controller)
            } else {
                // Do not leave protected records mounted behind an opaque
                // overlay: VoiceOver and UI automation must not be able to
                // enumerate health data before authentication succeeds.
                content
                    .environmentObject(controller)
            }
        }
        .background(CT.Color.bgBase)
        .onChange(of: scenePhase) { _, newValue in
            if newValue != .active {
                controller.lockForPrivacy()
            }
        }
    }

    private var shouldProtect: Bool {
        guard controller.isEnabled else { return false }
        return scenePhase != .active || controller.phase != .unlocked
    }
}

private struct AppLockScreen: View {
    @ObservedObject var controller: AppLockController

    var body: some View {
        VStack(spacing: CT.Space.s5) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: CT.Size.emptySymbol, weight: .semibold))
                .foregroundStyle(CT.Color.primary)
                .accessibilityHidden(true)
            Text(AppLockCopy.unlockTitle)
                .font(CT.Font.title2)
                .foregroundStyle(CT.Color.inkPrimary)
                .accessibilityIdentifier("m8.lock.screen")
            Text(AppLockCopy.unlockDescription)
                .font(CT.Font.bodyReading)
                .foregroundStyle(CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
            if controller.phase == .failed {
                Text(AppLockCopy.failed)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.danger)
            }
            Button {
                Task { await controller.unlock() }
            } label: {
                if controller.phase == .authenticating {
                    ProgressView()
                        .tint(CT.Color.inkOnPrimary)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(AppLockCopy.retry)
                        .font(CT.Font.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(CT.Color.primary)
            .frame(height: CT.Size.primaryButtonHeight)
            .disabled(controller.phase == .authenticating)
            .accessibilityIdentifier("m8.lock.retry")
            Spacer()
        }
        .padding(CT.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CT.Color.bgBase)
        #if DEBUG
        .screenshotReady(.lock, when: controller.phase == .failed)
        #endif
        .task {
            guard controller.phase == .locked else { return }
            _ = await controller.unlock()
        }
    }
}
