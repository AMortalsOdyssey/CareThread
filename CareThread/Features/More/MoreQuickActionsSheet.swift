import SwiftUI

struct MoreQuickActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onMedication: () -> Void = {}
    var onFollowUp: () -> Void = {}
    var onManualRecord: () -> Void = {}
    var onImport: () -> Void = {}
    var onSystemCalendar: () -> Void = {}
    var onExport: () -> Void = {}
    var onCompare: () -> Void = {}
    var onTransfer: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                action(
                    title: Copy.MoreTools.medicationReminder,
                    subtitle: Copy.MoreTools.medicationReminderDetail,
                    symbol: "pills.fill",
                    id: "medication",
                    callback: onMedication
                )
                action(
                    title: Copy.MoreTools.followUpReminder,
                    subtitle: Copy.MoreTools.followUpReminderDetail,
                    symbol: "calendar.badge.clock",
                    id: "followup",
                    callback: onFollowUp
                )
                action(
                    title: Copy.MoreTools.manualRecord,
                    subtitle: Copy.MoreTools.manualRecordDetail,
                    symbol: "square.and.pencil",
                    id: "manual",
                    callback: onManualRecord
                )
                action(
                    title: Copy.MoreTools.importFile,
                    subtitle: Copy.MoreTools.importFileDetail,
                    symbol: "photo.on.rectangle.angled",
                    id: "import",
                    callback: onImport
                )
                action(
                    title: Copy.MoreTools.systemCalendar,
                    subtitle: Copy.MoreTools.systemCalendarDetail,
                    symbol: "calendar.badge.plus",
                    id: "calendar",
                    callback: onSystemCalendar
                )
                action(
                    title: Copy.MoreTools.export,
                    subtitle: Copy.MoreTools.exportDetail,
                    symbol: "square.and.arrow.up",
                    id: "export",
                    callback: onExport
                )
                action(
                    title: Copy.MoreTools.compare,
                    subtitle: Copy.MoreTools.compareDetail,
                    symbol: "chart.xyaxis.line",
                    id: "compare",
                    callback: onCompare
                )
                action(
                    title: Copy.MoreTools.transfer,
                    subtitle: Copy.MoreTools.transferDetail,
                    symbol: "iphone.gen3.radiowaves.left.and.right",
                    id: "transfer",
                    callback: onTransfer
                )
            }
            .listStyle(.plain)
            .navigationTitle(Copy.MoreTools.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Medication.done) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("m45.more")
    }

    private func action(
        title: String,
        subtitle: String,
        symbol: String,
        id: String,
        callback: @escaping () -> Void
    ) -> some View {
        Button {
            dismiss()
            callback()
        } label: {
            M4M5IconRow(
                title: title,
                subtitle: subtitle,
                systemImage: symbol
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("m45.more.\(id)")
    }
}
