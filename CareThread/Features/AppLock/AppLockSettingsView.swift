import SwiftUI

struct AppLockSettingsView: View {
    @EnvironmentObject private var controller: AppLockController
    @State private var requestedValue = false
    @State private var showEnableConfirmation = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: CT.Space.s3) {
                    Image(systemName: "lock.shield")
                        .font(CT.Font.title1)
                        .foregroundStyle(CT.Color.primary)
                    Text(AppLockCopy.title)
                        .font(CT.Font.title2)
                        .foregroundStyle(CT.Color.inkPrimary)
                    Text(AppLockCopy.description)
                        .font(CT.Font.bodyReading)
                        .foregroundStyle(CT.Color.inkSecondary)
                }
                .padding(.vertical, CT.Space.s3)
            }

            Section {
                Toggle(
                    AppLockCopy.toggle,
                    isOn: Binding(
                        get: { requestedValue },
                        set: handleToggle
                    )
                )
                .font(CT.Font.body)
                .tint(CT.Color.primary)
                .disabled(!controller.canEnable && !controller.isEnabled)
                .accessibilityIdentifier("m8.lock.toggle")

                Text(controller.isEnabled ? AppLockCopy.enabled : AppLockCopy.disabled)
                    .font(CT.Font.footnote)
                    .foregroundStyle(
                        controller.isEnabled ? CT.Color.success : CT.Color.inkSecondary
                    )

                if !controller.canEnable && !controller.isEnabled {
                    Text(AppLockCopy.unavailable)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.warningOnContainer)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.danger)
                }
            }

            Section {
                Label(AppLockCopy.sensitiveNotice, systemImage: "exclamationmark.shield")
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.warningOnContainer)
            }
            .listRowBackground(CT.Color.warningContainer)

            Section {
                Label(AppLockCopy.systemLockNotice, systemImage: "iphone.gen3")
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(AppLockCopy.systemLockNotice)
                    .accessibilityIdentifier("m8.lock.systemNotice")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(AppLockCopy.navigationTitle)
        .onAppear {
            requestedValue = controller.isEnabled
        }
        .confirmationDialog(
            AppLockCopy.title,
            isPresented: $showEnableConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLockCopy.toggle) {
                Task { await enableAfterConfirmation() }
            }
            .accessibilityIdentifier("m8.lock.confirm")
            Button(AppLockCopy.cancel, role: .cancel) {
                requestedValue = controller.isEnabled
            }
        } message: {
            Text(AppLockCopy.description)
        }
        .accessibilityIdentifier("m8.lock.settings")
    }

    private func handleToggle(_ enabled: Bool) {
        statusMessage = nil
        if enabled {
            requestedValue = true
            showEnableConfirmation = true
        } else {
            Task {
                _ = await controller.setEnabled(false)
                requestedValue = false
            }
        }
    }

    @MainActor
    private func enableAfterConfirmation() async {
        let success = await controller.setEnabled(true)
        requestedValue = success
        statusMessage = success ? nil : AppLockCopy.failed
    }
}
