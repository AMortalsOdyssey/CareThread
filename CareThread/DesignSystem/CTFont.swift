import SwiftUI
import UIKit

extension CT {
    enum Font {
        static var display: SwiftUI.Font { scaledSystem(
            size: 34,
            weight: .bold,
            relativeTo: .largeTitle
        ) }
        static var title1: SwiftUI.Font { scaledSystem(
            size: 28,
            weight: .bold,
            relativeTo: .title1
        ) }
        static var title2: SwiftUI.Font { scaledSystem(
            size: 22,
            weight: .semibold,
            relativeTo: .title2
        ) }
        static var title3: SwiftUI.Font { scaledSystem(
            size: 20,
            weight: .semibold,
            relativeTo: .title3
        ) }
        static var headline: SwiftUI.Font { scaledSystem(
            size: 17,
            weight: .semibold,
            relativeTo: .headline
        ) }
        static var body: SwiftUI.Font { scaledSystem(
            size: 17,
            weight: .regular,
            relativeTo: .body
        ) }
        static var bodyReading: SwiftUI.Font { scaledSystem(
            size: 17,
            weight: .regular,
            relativeTo: .body
        ) }
        static var callout: SwiftUI.Font { scaledSystem(
            size: 16,
            weight: .regular,
            relativeTo: .callout
        ) }
        static var subhead: SwiftUI.Font { scaledSystem(
            size: 15,
            weight: .regular,
            relativeTo: .subheadline
        ) }
        static var footnote: SwiftUI.Font { scaledSystem(
            size: 13,
            weight: .regular,
            relativeTo: .footnote
        ) }
        static var caption: SwiftUI.Font { scaledSystem(
            size: 12,
            weight: .medium,
            relativeTo: .caption1
        ) }
        static var label: SwiftUI.Font { scaledSystem(
            size: 11,
            weight: .medium,
            relativeTo: .caption2
        ) }
        static var valueMono: SwiftUI.Font { scaledSystem(
            size: 17,
            weight: .semibold,
            relativeTo: .body
        ).monospacedDigit() }
        static var valueBig: SwiftUI.Font { scaledSystem(
            size: 22,
            weight: .semibold,
            relativeTo: .title2
        ).monospacedDigit() }

        static var elderDisplay: SwiftUI.Font { scaledSystem(
            size: 40,
            weight: .bold,
            relativeTo: .largeTitle
        ) }
        static var elderTitle2: SwiftUI.Font { scaledSystem(
            size: 28,
            weight: .semibold,
            relativeTo: .title1
        ) }
        static var elderHeadline: SwiftUI.Font { scaledSystem(
            size: 22,
            weight: .semibold,
            relativeTo: .title2
        ) }
        static var elderBody: SwiftUI.Font { scaledSystem(
            size: 20,
            weight: .regular,
            relativeTo: .title3
        ) }
        static var elderSubhead: SwiftUI.Font { scaledSystem(
            size: 18,
            weight: .regular,
            relativeTo: .body
        ) }
        static var elderFootnote: SwiftUI.Font { scaledSystem(
            size: 16,
            weight: .regular,
            relativeTo: .callout
        ) }
        static var elderValueBig: SwiftUI.Font { scaledSystem(
            size: 34,
            weight: .semibold,
            relativeTo: .largeTitle
        ).monospacedDigit() }

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
            relativeTo textStyle: UIKit.UIFont.TextStyle
        ) -> SwiftUI.Font {
            let baseFont = UIKit.UIFont.systemFont(
                ofSize: size,
                weight: weight
            )
            let scaledFont = UIKit.UIFontMetrics(
                forTextStyle: textStyle
            ).scaledFont(for: baseFont)
            return SwiftUI.Font(scaledFont)
        }
    }
}
