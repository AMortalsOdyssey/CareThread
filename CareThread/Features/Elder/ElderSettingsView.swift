import SwiftUI

struct ElderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("carethread.elderRemindersEnabled")
    private var remindersEnabled = true
    @AppStorage(ElderFontScale.storageKey)
    private var storedScale = ElderFontScale.standard.rawValue

    let onRequestStandardMode: () -> Void

    @State private var showDisclaimer = false

    private var scale: Binding<ElderFontScale> {
        Binding(
            get: {
                ElderFontScale(rawValue: storedScale) ?? .standard
            },
            set: {
                storedScale = $0.rawValue
                AppLog.userAction.info(
                    "Elder in-app font scale changed"
                )
            }
        )
    }

    var body: some View {
        List {
            Toggle(isOn: $remindersEnabled) {
                Label(Copy.Elder.reminders, systemImage: "bell")
                    .font(CT.Font.elderHeadline)
                    .foregroundStyle(CT.Color.inkPrimary)
            }
            .frame(minHeight: CT.Size.elderListRowHeight)
            .tint(CT.Color.primary)
            .accessibilityIdentifier("elder.settings.reminders")

            VStack(alignment: .leading, spacing: CT.Space.s3) {
                Label(Copy.Elder.fontSize, systemImage: "textformat.size")
                    .font(CT.Font.elderHeadline)
                    .foregroundStyle(CT.Color.inkPrimary)
                Picker(Copy.Elder.fontSize, selection: scale) {
                    ForEach(ElderFontScale.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }
            .frame(minHeight: CT.Size.elderListRowHeight)
            .padding(.vertical, CT.Space.s2)
            .accessibilityIdentifier("elder.settings.fontScale")

            Button(action: onRequestStandardMode) {
                Label(
                    Copy.Elder.switchStandard,
                    systemImage: "rectangle.grid.2x2"
                )
                .font(CT.Font.elderHeadline)
                .foregroundStyle(CT.Color.primary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: CT.Size.elderListRowHeight,
                    alignment: .leading
                )
            }
            .accessibilityIdentifier("elder.settings.standard")

            Button {
                showDisclaimer = true
            } label: {
                Label(
                    Copy.Elder.about,
                    systemImage: "info.circle"
                )
                .font(CT.Font.elderHeadline)
                .foregroundStyle(CT.Color.inkPrimary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: CT.Size.elderListRowHeight,
                    alignment: .leading
                )
            }
            .accessibilityIdentifier("elder.settings.about")
        }
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Elder.settings)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(Copy.Common.done) {
                    dismiss()
                }
                .font(CT.Font.elderSubhead)
                .frame(minHeight: CT.Size.elderTouchTarget)
            }
        }
        .alert(
            Copy.Elder.disclaimerTitle,
            isPresented: $showDisclaimer
        ) {
            Button(Copy.Common.acknowledge) {}
        } message: {
            Text(Copy.disclaimer)
        }
        .dynamicTypeSize(...ElderDynamicTypePolicy.maximum)
        .accessibilityIdentifier("elder.settings")
    }
}
