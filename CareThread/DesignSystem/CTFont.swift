import SwiftUI
import UIKit

extension CT {
    enum Font {
        static let display = scaledSystem(
            size: 34,
            weight: .bold,
            relativeTo: .largeTitle
        )
        static let title1 = scaledSystem(
            size: 28,
            weight: .bold,
            relativeTo: .title
        )
        static let title2 = scaledSystem(
            size: 22,
            weight: .semibold,
            relativeTo: .title2
        )
        static let title3 = scaledSystem(
            size: 20,
            weight: .semibold,
            relativeTo: .title3
        )
        static let headline = scaledSystem(
            size: 17,
            weight: .semibold,
            relativeTo: .headline
        )
        static let body = scaledSystem(
            size: 17,
            weight: .regular,
            relativeTo: .body
        )
        static let bodyReading = scaledSystem(
            size: 17,
            weight: .regular,
            relativeTo: .body
        )
        static let callout = scaledSystem(
            size: 16,
            weight: .regular,
            relativeTo: .callout
        )
        static let subhead = scaledSystem(
            size: 15,
            weight: .regular,
            relativeTo: .subheadline
        )
        static let footnote = scaledSystem(
            size: 13,
            weight: .regular,
            relativeTo: .footnote
        )
        static let caption = scaledSystem(
            size: 12,
            weight: .medium,
            relativeTo: .caption
        )
        static let label = scaledSystem(
            size: 11,
            weight: .medium,
            relativeTo: .caption2
        )
        static let valueMono = scaledSystem(
            size: 17,
            weight: .semibold,
            relativeTo: .body
        ).monospacedDigit()
        static let valueBig = scaledSystem(
            size: 22,
            weight: .semibold,
            relativeTo: .title2
        ).monospacedDigit()

        static let elderDisplay = scaledSystem(
            size: 40,
            weight: .bold,
            relativeTo: .largeTitle
        )
        static let elderTitle2 = scaledSystem(
            size: 28,
            weight: .semibold,
            relativeTo: .title
        )
        static let elderHeadline = scaledSystem(
            size: 22,
            weight: .semibold,
            relativeTo: .title2
        )
        static let elderBody = scaledSystem(
            size: 20,
            weight: .regular,
            relativeTo: .title3
        )
        static let elderSubhead = scaledSystem(
            size: 18,
            weight: .regular,
            relativeTo: .body
        )
        static let elderFootnote = scaledSystem(
            size: 16,
            weight: .regular,
            relativeTo: .callout
        )
        static let elderValueBig = scaledSystem(
            size: 34,
            weight: .semibold,
            relativeTo: .largeTitle
        ).monospacedDigit()

        static func headline(for mode: DisplayMode) -> SwiftUI.Font {
            mode == .elder ? elderHeadline : headline
        }

        static func body(for mode: DisplayMode) -> SwiftUI.Font {
            mode == .elder ? elderBody : body
        }

        /// Keeps the design-token base size while opting into the system
        /// Dynamic Type curve for the matching semantic text role.
        private static func scaledSystem(
            size: CGFloat,
            weight: UIKit.UIFont.Weight,
            relativeTo textStyle: SwiftUI.Font.TextStyle
        ) -> SwiftUI.Font {
            let baseFont = UIKit.UIFont.systemFont(
                ofSize: size,
                weight: weight
            )
            return SwiftUI.Font.custom(
                baseFont.fontName,
                size: size,
                relativeTo: textStyle
            )
        }
    }
}
