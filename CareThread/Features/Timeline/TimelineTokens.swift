import CoreGraphics

extension CT {
    enum Timeline {
        static let axisWidth: CGFloat = 2.5
        static let normalNode: CGFloat = 12
        static let keyNode: CGFloat = 16
        static let keyNodeBorder: CGFloat = 2.5
        static let monthHeaderHeight: CGFloat = 32
        static let axisColumnWidth: CGFloat = 28
        static let eventSpacing: CGFloat = 0
        static let latestThreshold = 12
        static let titleLineLimit = 2
        static let detailLineLimit = 2
        static let returnButtonShadowOpacity = 0.12
        static let returnButtonShadowRadius: CGFloat = 8
        static let returnButtonShadowY: CGFloat = 4
    }
}

enum TimelineScrollPolicy {
    static func shouldShowReturnToLatest(
        visibleEventIndex: Int
    ) -> Bool {
        visibleEventIndex >= CT.Timeline.latestThreshold
    }
}
