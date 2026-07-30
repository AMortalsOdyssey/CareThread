import SwiftUI

extension CT {
    enum Font {
        static let display = SwiftUI.Font.system(size: 34, weight: .bold)
        static let title1 = SwiftUI.Font.system(size: 28, weight: .bold)
        static let title2 = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let title3 = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 17, weight: .regular)
        static let bodyReading = SwiftUI.Font.system(size: 17, weight: .regular)
        static let callout = SwiftUI.Font.system(size: 16, weight: .regular)
        static let subhead = SwiftUI.Font.system(size: 15, weight: .regular)
        static let footnote = SwiftUI.Font.system(size: 13, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let label = SwiftUI.Font.system(size: 11, weight: .medium)
        static let valueMono = SwiftUI.Font.system(size: 17, weight: .semibold).monospacedDigit()
        static let valueBig = SwiftUI.Font.system(size: 22, weight: .semibold).monospacedDigit()

        static let elderDisplay = SwiftUI.Font.system(size: 40, weight: .bold)
        static let elderTitle2 = SwiftUI.Font.system(size: 28, weight: .semibold)
        static let elderHeadline = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let elderBody = SwiftUI.Font.system(size: 20, weight: .regular)
        static let elderSubhead = SwiftUI.Font.system(size: 18, weight: .regular)
        static let elderFootnote = SwiftUI.Font.system(size: 16, weight: .regular)
        static let elderValueBig = SwiftUI.Font.system(size: 34, weight: .semibold).monospacedDigit()

        static func headline(for mode: DisplayMode) -> SwiftUI.Font {
            mode == .elder ? elderHeadline : headline
        }

        static func body(for mode: DisplayMode) -> SwiftUI.Font {
            mode == .elder ? elderBody : body
        }
    }
}

