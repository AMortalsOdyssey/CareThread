import SwiftData
import SwiftUI

@MainActor
final class TimelineViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var events: [TimelineEvent] = []
    @Published private(set) var hasMore = false
    @Published var filter: TimelineFilter

    private var context: ModelContext?
    private var patientID: UUID?
    private var nowProvider: () -> Date

    init(
        initialFilter: TimelineFilter = .all,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.filter = initialFilter
        self.nowProvider = nowProvider
    }

    func configure(context: ModelContext) {
        self.context = context
    }

    func reload(patientID: UUID) {
        self.patientID = patientID
        events = []
        hasMore = false
        load(offset: 0)
    }

    func selectFilter(_ value: TimelineFilter) {
        guard value != filter else { return }
        filter = value
        AppLog.userAction.info(
            "Timeline filter changed to \(value.rawValue, privacy: .private(mask: .hash))"
        )
        guard let patientID else { return }
        reload(patientID: patientID)
    }

    func loadMore() {
        guard hasMore, state != .loading else { return }
        load(offset: events.count)
    }

    private func load(offset: Int) {
        guard let context, let patientID else {
            state = .failed
            AppLog.data.error("Timeline load rejected because context or member was missing")
            return
        }
        state = .loading
        do {
            let page = try TimelineRepository(context: context).page(
                patientID: patientID,
                filter: filter,
                request: TimelinePageRequest(offset: offset),
                now: nowProvider()
            )
            if offset == 0 {
                events = page.events
            } else {
                let known = Set(events.map(\.id))
                events.append(
                    contentsOf: page.events.filter { !known.contains($0.id) }
                )
            }
            hasMore = page.hasMore
            state = .loaded
            AppLog.data.info(
                "Timeline loaded \(page.events.count) events for member \(patientID.uuidString, privacy: .private(mask: .hash))"
            )
        } catch {
            state = .failed
            AppLog.data.error(
                "Timeline load failed for member \(patientID.uuidString, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
    }
}

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let patientID: UUID
    let onSelect: (TimelineEvent.Destination) -> Void

    @StateObject private var viewModel: TimelineViewModel
    @State private var isAwayFromLatest = false

    init(
        patientID: UUID,
        initialFilter: TimelineFilter = .all,
        nowProvider: @escaping () -> Date = Date.init,
        onSelect: @escaping (TimelineEvent.Destination) -> Void = { _ in }
    ) {
        self.patientID = patientID
        self.onSelect = onSelect
        _viewModel = StateObject(
            wrappedValue: TimelineViewModel(
                initialFilter: initialFilter,
                nowProvider: nowProvider
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                content
                if isAwayFromLatest && !viewModel.events.isEmpty {
                    Button {
                        if reduceMotion {
                            proxy.scrollTo(TimelineAnchor.latest, anchor: .top)
                        } else {
                            withAnimation(.smooth) {
                                proxy.scrollTo(
                                    TimelineAnchor.latest,
                                    anchor: .top
                                )
                            }
                        }
                        isAwayFromLatest = false
                        AppLog.userAction.info("Timeline returned to latest event")
                    } label: {
                        Label(
                            Copy.Timeline.returnToLatest,
                            systemImage: "arrow.up"
                        )
                        .font(CT.Font.subhead)
                        .foregroundStyle(CT.Color.primaryOnContainer)
                        .padding(.horizontal, CT.Space.s4)
                        .frame(minHeight: CT.Size.secondaryButtonHeight)
                        .background(CT.Color.primaryContainer)
                        .clipShape(Capsule())
                        .shadow(
                            color: CT.Color.inkPrimary.opacity(
                                CT.Timeline.returnButtonShadowOpacity
                            ),
                            radius: CT.Timeline.returnButtonShadowRadius,
                            y: CT.Timeline.returnButtonShadowY
                        )
                    }
                    .padding(CT.Space.s4)
                    .accessibilityIdentifier("m6.timeline.returnLatest")
                }
            }
        }
        .background(CT.Color.bgBase)
        .navigationTitle(Copy.Timeline.navigationTitle)
        .task(id: patientID) {
            viewModel.configure(context: modelContext)
            viewModel.reload(patientID: patientID)
        }
        .onChange(of: viewModel.filter) { _, _ in
            isAwayFromLatest = false
        }
        .accessibilityIdentifier("m6.timeline")
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: CT.Space.s3) {
            filterBar
            switch viewModel.state {
            case .idle, .loading:
                if viewModel.events.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("m6.timeline.loading")
                } else {
                    timelineList
                }
            case .failed:
                ContentUnavailableView(
                    Copy.Timeline.loadFailed,
                    systemImage: "exclamationmark.triangle"
                )
            default:
                if viewModel.events.isEmpty {
                    ContentUnavailableView(
                        viewModel.filter == .all
                            ? Copy.Timeline.empty
                            : Copy.Timeline.emptyFiltered,
                        systemImage: "calendar.day.timeline.left"
                    )
                    .accessibilityIdentifier("m6.timeline.empty")
                } else {
                    timelineList
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CT.Space.s2) {
                ForEach(TimelineFilter.allCases) { filter in
                    Button {
                        viewModel.selectFilter(filter)
                    } label: {
                        Text(filter.title)
                            .font(CT.Font.caption)
                            .foregroundStyle(
                                viewModel.filter == filter
                                    ? CT.Color.primaryOnContainer
                                    : CT.Color.inkSecondary
                            )
                            .padding(.horizontal, CT.Space.s3)
                            .frame(minHeight: CT.Size.secondaryButtonHeight)
                            .background(
                                viewModel.filter == filter
                                    ? CT.Color.primaryContainer
                                    : CT.Color.bgElevated
                            )
                            .clipShape(Capsule())
                    }
                    .accessibilityValue(
                        viewModel.filter == filter
                            ? Copy.Common.selected
                            : Copy.Common.notSelected
                    )
                    .accessibilityIdentifier(
                        "m6.timeline.filter.\(filter.rawValue)"
                    )
                }
            }
            .padding(.horizontal, CT.Space.s4)
        }
        .accessibilityIdentifier("m6.timeline.filters")
    }

    private var timelineList: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: CT.Timeline.eventSpacing,
                pinnedViews: [.sectionHeaders]
            ) {
                Color.clear
                    .frame(height: CT.Space.s1)
                    .id(TimelineAnchor.latest)
                ForEach(monthSections) { section in
                    Section {
                        ForEach(
                            Array(section.events.enumerated()),
                            id: \.element.id
                        ) { localIndex, event in
                            let globalIndex = section.startIndex + localIndex
                            TimelineEventRow(event: event) {
                                AppLog.userAction.info(
                                    "Timeline event opened \(event.id, privacy: .private(mask: .hash))"
                                )
                                onSelect(event.destination)
                            }
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: TimelineRowPositionPreferenceKey.self,
                                        value: [
                                            event.id: geometry.frame(
                                                in: .named(
                                                    TimelineAnchor.scrollSpace
                                                )
                                            ).minY
                                        ]
                                    )
                                }
                            }
                            .onAppear {
                                if globalIndex == viewModel.events.count - 1 {
                                    viewModel.loadMore()
                                }
                            }
                        }
                    } header: {
                        Text(section.title)
                            .font(CT.Font.headline)
                            .foregroundStyle(CT.Color.inkSecondary)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: CT.Timeline.monthHeaderHeight,
                                alignment: .leading
                            )
                            .padding(.horizontal, CT.Space.s4)
                            .background(CT.Color.bgBase)
                    }
                }
                if viewModel.hasMore {
                    Button(Copy.Timeline.loadMore) {
                        viewModel.loadMore()
                    }
                    .buttonStyle(CTSecondaryButtonStyle())
                    .padding(.horizontal, CT.Space.s4)
                    .accessibilityIdentifier("m6.timeline.loadMore")
                }
            }
            .padding(.bottom, CT.Space.s8)
        }
        .coordinateSpace(name: TimelineAnchor.scrollSpace)
        .onPreferenceChange(TimelineRowPositionPreferenceKey.self) {
            positions in
            let topVisibleIndex = viewModel.events.enumerated()
                .compactMap { index, event -> (Int, CGFloat)? in
                    guard let position = positions[event.id],
                          position >= CT.Timeline.eventSpacing else {
                        return nil
                    }
                    return (index, position)
                }
                .min { $0.1 < $1.1 }?
                .0
            if let topVisibleIndex {
                isAwayFromLatest =
                    TimelineScrollPolicy.shouldShowReturnToLatest(
                        visibleEventIndex: topVisibleIndex
                    )
            }
        }
        .accessibilityIdentifier("m6.timeline.list")
    }

    private var monthSections: [TimelineMonthSection] {
        TimelineMonthSection.make(from: viewModel.events)
    }
}

private enum TimelineAnchor {
    static let latest = "timeline-latest"
    static let scrollSpace = "timeline-scroll-space"
}

private struct TimelineRowPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(
        value: inout [String: CGFloat],
        nextValue: () -> [String: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct TimelineMonthSection: Identifiable {
    let id: Date
    let title: String
    let events: [TimelineEvent]
    let startIndex: Int

    static func make(
        from events: [TimelineEvent],
        calendar: Calendar = CTDate.calendar
    ) -> [TimelineMonthSection] {
        var sections: [TimelineMonthSection] = []
        var runningIndex = 0
        for event in events {
            let components = calendar.dateComponents(
                [.year, .month],
                from: event.date
            )
            guard let month = calendar.date(from: components) else { continue }
            if let last = sections.last, last.id == month {
                sections[sections.count - 1] = TimelineMonthSection(
                    id: last.id,
                    title: last.title,
                    events: last.events + [event],
                    startIndex: last.startIndex
                )
            } else {
                sections.append(
                    TimelineMonthSection(
                        id: month,
                        title: TimelineDateFormatters.month.string(from: month),
                        events: [event],
                        startIndex: runningIndex
                    )
                )
            }
            runningIndex += 1
        }
        return sections
    }
}

private struct TimelineEventRow: View {
    let event: TimelineEvent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: CT.Space.s3) {
                node
                    .frame(width: CT.Timeline.axisColumnWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: CT.Space.s2) {
                    Text(
                        Copy.Timeline.dayAndType(
                            day: TimelineDateFormatters.day.string(
                                from: event.date
                            ),
                            type: eventType
                        )
                    )
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkTertiary)
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.title)
                            .font(CT.Font.headline)
                            .foregroundStyle(CT.Color.inkPrimary)
                            .lineLimit(CT.Timeline.titleLineLimit)
                        Spacer(minLength: CT.Space.s2)
                        if event.isAbnormal {
                            statusLabel(
                                Copy.Timeline.abnormal,
                                symbol: "exclamationmark.triangle.fill",
                                foreground: CT.Color.dangerOnContainer,
                                background: CT.Color.dangerContainer
                            )
                        } else if event.isOverdue {
                            statusLabel(
                                Copy.Timeline.overdue,
                                symbol: "clock.badge.exclamationmark",
                                foreground: CT.Color.dangerOnContainer,
                                background: CT.Color.dangerContainer
                            )
                        }
                    }
                    Text(event.detail)
                        .font(CT.Font.callout)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .lineSpacing(CT.Space.s1)
                        .lineLimit(CT.Timeline.detailLineLimit)
                }
                .padding(CT.Space.s4)
                .background(CT.Color.bgElevated)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: CT.Radius.card,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: CT.Radius.card,
                        style: .continuous
                    )
                    .stroke(CT.Color.outline, lineWidth: M3Layout.hairline)
                }
                .padding(.bottom, CT.Space.s3)
            }
            .padding(.horizontal, CT.Space.s4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Copy.Timeline.openDetail)
        .accessibilityIdentifier("m6.timeline.event.\(event.id)")
    }

    private var node: some View {
        ZStack {
            Rectangle()
                .fill(CT.Color.thread)
                .frame(width: CT.Timeline.axisWidth)
            Circle()
                .fill(event.isAbnormal ? CT.Color.bgElevated : eventColor)
                .frame(
                    width: event.isAbnormal
                        ? CT.Timeline.keyNode
                        : CT.Timeline.normalNode,
                    height: event.isAbnormal
                        ? CT.Timeline.keyNode
                        : CT.Timeline.normalNode
                )
                .overlay {
                    if event.isAbnormal {
                        Circle()
                            .stroke(
                                eventColor,
                                lineWidth: CT.Timeline.keyNodeBorder
                            )
                    }
                }
        }
        .frame(maxHeight: .infinity)
    }

    private var eventType: String {
        if let recordType = event.recordType {
            return recordType.displayName
        }
        return Copy.Timeline.eventType(event.kind)
    }

    private var eventColor: Color {
        if let type = event.recordType {
            return type.semanticColor
        }
        switch event.kind {
        case .medicalRecord:
            return CT.Color.other
        case .medicationStarted, .medicationAdjusted, .medicationStopped:
            return CT.Color.prescription
        case .medicalOrder:
            return CT.Color.primary
        case .followUpDue:
            return event.isOverdue ? CT.Color.danger : CT.Color.primary
        case .followUpCompleted:
            return CT.Color.success
        }
    }

    private func statusLabel(
        _ title: String,
        symbol: String,
        foreground: Color,
        background: Color
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(CT.Font.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, CT.Space.s2)
            .frame(minHeight: CT.Size.chipHeight)
            .background(background)
            .clipShape(
                RoundedRectangle(cornerRadius: CT.Radius.chip)
            )
    }
}

private enum TimelineDateFormatters {
    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = CTDate.calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = CTDate.calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "d"
        return formatter
    }()
}
