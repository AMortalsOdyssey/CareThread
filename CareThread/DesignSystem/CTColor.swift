import SwiftUI

enum CT {
    enum Color {
        static let bgBase = SwiftUI.Color("CTBgBase")
        static let bgElevated = SwiftUI.Color("CTBgElevated")
        static let bgInset = SwiftUI.Color("CTBgInset")
        static let separator = SwiftUI.Color("CTSeparator")
        static let outline = SwiftUI.Color("CTOutline")
        static let inkPrimary = SwiftUI.Color("CTInkPrimary")
        static let inkSecondary = SwiftUI.Color("CTInkSecondary")
        static let inkTertiary = SwiftUI.Color("CTInkTertiary")
        static let inkDisabled = SwiftUI.Color("CTInkDisabled")
        static let inkOnPrimary = SwiftUI.Color("CTInkOnPrimary")
        /// Fixed dark chrome for the full-screen original viewer in both
        /// appearances. Unlike semantic text ink, this must not invert.
        static let viewerChrome = SwiftUI.Color("CTViewerChrome")
        static let primary = SwiftUI.Color("CTPrimary")
        static let primaryPressed = SwiftUI.Color("CTPrimaryPressed")
        static let primaryContainer = SwiftUI.Color("CTPrimaryContainer")
        static let primaryOnContainer = SwiftUI.Color("CTPrimaryOnContainer")
        static let thread = SwiftUI.Color("CTThread")
        static let danger = SwiftUI.Color("CTDanger")
        static let dangerContainer = SwiftUI.Color("CTDangerContainer")
        static let dangerOnContainer = SwiftUI.Color("CTDangerOnContainer")
        static let success = SwiftUI.Color("CTSuccess")
        static let successContainer = SwiftUI.Color("CTSuccessContainer")
        static let successOnContainer = SwiftUI.Color("CTSuccessOnContainer")
        static let warning = SwiftUI.Color("CTWarning")
        static let warningContainer = SwiftUI.Color("CTWarningContainer")
        static let warningOnContainer = SwiftUI.Color("CTWarningOnContainer")
        static let imaging = SwiftUI.Color("CTTypeImaging")
        static let lab = SwiftUI.Color("CTTypeLab")
        static let pathology = SwiftUI.Color("CTTypePathology")
        static let discharge = SwiftUI.Color("CTTypeDischarge")
        static let outpatient = SwiftUI.Color("CTTypeOutpatient")
        static let prescription = SwiftUI.Color("CTTypePrescription")
        static let other = SwiftUI.Color("CTTypeOther")
    }
}
