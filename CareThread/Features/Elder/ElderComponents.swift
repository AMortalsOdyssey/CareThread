import SwiftUI

struct ElderPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CT.Font.elderHeadline)
            .foregroundStyle(CT.Color.inkOnPrimary)
            .frame(maxWidth: .infinity, minHeight: CT.Size.elderPrimaryButtonHeight)
            .padding(.horizontal, CT.Space.s4)
            .background(
                configuration.isPressed
                    ? CT.Color.primaryPressed
                    : CT.Color.primary
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.elderButton,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
    }
}

struct ElderSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CT.Font.elderHeadline)
            .foregroundStyle(CT.Color.primary)
            .frame(maxWidth: .infinity, minHeight: CT.Size.elderPrimaryButtonHeight)
            .padding(.horizontal, CT.Space.s4)
            .background(
                configuration.isPressed
                    ? CT.Color.primaryContainer
                    : CT.Color.bgElevated
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.elderButton,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: CT.Radius.elderButton,
                    style: .continuous
                )
                .stroke(CT.Color.outline, lineWidth: CT.Stroke.hairline)
            }
            .contentShape(Rectangle())
    }
}

struct ElderRecordCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(CT.Space.elderCard)
            .frame(
                maxWidth: .infinity,
                minHeight: CT.Size.recordCardMinHeight,
                alignment: .leading
            )
            .background(CT.Color.bgElevated)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.elderCard,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: CT.Radius.elderCard,
                    style: .continuous
                )
                .stroke(CT.Color.outline, lineWidth: CT.Stroke.hairline)
            }
    }
}

struct ElderBigChoiceButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: CT.Space.s2) {
                Image(systemName: systemImage)
                    .font(CT.Font.elderTitle2)
                Text(title)
                    .font(CT.Font.elderHeadline)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(CT.Color.primaryOnContainer)
            .frame(
                maxWidth: .infinity,
                minHeight: CT.Size.elderChoiceButtonHeight
            )
            .padding(.horizontal, CT.Space.s2)
            .background(CT.Color.primaryContainer)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CT.Radius.elderButton,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ElderModeSwitchConfirmationView: View {
    let targetMode: DisplayMode
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var title: String {
        targetMode == .elder
            ? Copy.Elder.switchToElderTitle
            : Copy.Elder.switchToStandardTitle
    }

    private var bodyText: String {
        targetMode == .elder
            ? Copy.Elder.switchToElderBody
            : Copy.Elder.switchToStandardBody
    }

    private var actionTitle: String {
        targetMode == .elder
            ? Copy.Elder.switchToElderAction
            : Copy.Elder.switchToStandardAction
    }

    var body: some View {
        VStack(spacing: CT.Space.s6) {
            Spacer()
            Image(systemName: targetMode == .elder ? "textformat.size.larger" : "rectangle.grid.2x2")
                .font(.system(size: CT.Size.elderEmptySymbol))
                .foregroundStyle(CT.Color.primary)
                .frame(
                    width: CT.Size.elderChoiceButtonHeight,
                    height: CT.Size.elderChoiceButtonHeight
                )
                .background(CT.Color.primaryContainer)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: CT.Radius.elderCard,
                        style: .continuous
                    )
                )
            Text(title)
                .font(CT.Font.elderTitle2)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(CT.Font.elderBody)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(8)
            Spacer()
            VStack(spacing: CT.Space.s3) {
                Button(actionTitle, action: onConfirm)
                    .buttonStyle(ElderPrimaryButtonStyle())
                    .accessibilityIdentifier("elder.mode.confirm")
                Button(Copy.Elder.notNow, action: onCancel)
                    .buttonStyle(ElderSecondaryButtonStyle())
                    .accessibilityIdentifier("elder.mode.cancel")
            }
        }
        .padding(CT.Space.elderScreen)
        .background(CT.Color.bgBase)
        .dynamicTypeSize(...ElderDynamicTypePolicy.maximum)
        .accessibilityIdentifier("elder.mode.confirmation")
    }
}
