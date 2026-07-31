import SwiftUI

extension CT.Size {
    static let dashboardLoadingMinHeight: CGFloat = 180
    static let dashboardQuickActionMinHeight: CGFloat = 88
}

extension CT {
    enum Stroke {
        static let hairline: CGFloat = 1
    }

    enum Opacity {
        static let subtle: Double = 0.24
        static let emphasis: Double = 0.32
    }
}

enum M4M5CardTone {
    case standard
    case primary
    case warning
    case danger
}

struct M4M5Card<Content: View>: View {
    var tone: M4M5CardTone = .standard
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CT.Space.s4)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CT.Radius.card, style: .continuous)
                    .stroke(border, lineWidth: CT.Stroke.hairline)
            }
    }

    private var background: Color {
        switch tone {
        case .standard: CT.Color.bgElevated
        case .primary: CT.Color.primaryContainer
        case .warning: CT.Color.warningContainer
        case .danger: CT.Color.dangerContainer
        }
    }

    private var border: Color {
        switch tone {
        case .standard: CT.Color.outline
        case .primary: CT.Color.primary.opacity(CT.Opacity.subtle)
        case .warning: CT.Color.warning.opacity(CT.Opacity.emphasis)
        case .danger: CT.Color.danger.opacity(CT.Opacity.emphasis)
        }
    }
}

struct M4M5SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CT.Font.title3)
            .foregroundStyle(CT.Color.inkPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct M4M5PrimaryButton: View {
    let title: String
    let systemImage: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(CT.Font.headline)
            } icon: {
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: CT.Size.primaryButtonHeight)
            .foregroundStyle(CT.Color.inkOnPrimary)
            .background(isEnabled ? CT.Color.primary : CT.Color.inkDisabled)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.primaryButton, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .contentShape(Rectangle())
    }
}

struct M4M5StatusBanner: View {
    let message: String
    var isDanger = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: CT.Space.s3) {
            Image(systemName: isDanger ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isDanger ? CT.Color.danger : CT.Color.warning)
            Text(message)
                .font(CT.Font.subhead)
                .foregroundStyle(isDanger ? CT.Color.dangerOnContainer : CT.Color.warningOnContainer)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(CT.Font.subhead.weight(.semibold))
            }
        }
        .padding(CT.Space.s3)
        .background(isDanger ? CT.Color.dangerContainer : CT.Color.warningContainer)
        .clipShape(RoundedRectangle(cornerRadius: CT.Radius.input, style: .continuous))
    }
}

struct M4M5IconRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: CT.Space.s3) {
            Image(systemName: systemImage)
                .font(CT.Font.headline)
                .foregroundStyle(CT.Color.primary)
                .frame(width: CT.Size.leadingIcon, height: CT.Size.leadingIcon)
                .background(CT.Color.primaryContainer)
                .clipShape(RoundedRectangle(cornerRadius: CT.Radius.input, style: .continuous))
            VStack(alignment: .leading, spacing: CT.Space.s1) {
                Text(title)
                    .font(CT.Font.body)
                    .foregroundStyle(CT.Color.inkPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: CT.Space.s2)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(CT.Color.inkTertiary)
            }
        }
        .frame(minHeight: CT.Size.listRowHeight)
        .contentShape(Rectangle())
    }
}
