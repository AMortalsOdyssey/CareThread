import SwiftUI

struct DatabaseRecoveryView: View {
    let info: DatabaseRecoveryInfo

    var body: some View {
        VStack(spacing: CT.Space.s4) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: CT.Size.emptySymbol))
                .foregroundStyle(CT.Color.warning)
                .accessibilityHidden(true)
            Text(Copy.Recovery.title)
                .font(CT.Font.title2)
                .foregroundStyle(CT.Color.inkPrimary)
            Text(info.userMessage)
                .font(CT.Font.body)
                .foregroundStyle(CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
            Text("\(Copy.Recovery.referenceCode)：\(info.referenceCode)")
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
                .textSelection(.enabled)
        }
        .padding(CT.Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CT.Color.bgBase)
        .accessibilityIdentifier("databaseRecoveryView")
    }
}
