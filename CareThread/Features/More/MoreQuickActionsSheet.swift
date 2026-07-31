import SwiftUI

enum MoreQuickAction: String, CaseIterable, Identifiable {
    case camera
    case photos
    case files
    case manual
    case medication
    case followUp
    case calendar
    case export
    case compare
    case transfer

    var id: String { rawValue }

    static let sourceActions: [MoreQuickAction] = [
        .camera, .photos, .files, .manual
    ]
    static let toolActions: [MoreQuickAction] = [
        .medication, .followUp, .calendar, .export, .compare, .transfer
    ]

    var title: String {
        switch self {
        case .camera: Copy.MoreTools.camera
        case .photos: Copy.MoreTools.photos
        case .files: Copy.MoreTools.files
        case .manual: Copy.MoreTools.manualRecord
        case .medication: Copy.MoreTools.medicationReminder
        case .followUp: Copy.MoreTools.followUpReminder
        case .calendar: Copy.MoreTools.systemCalendar
        case .export: Copy.MoreTools.export
        case .compare: Copy.MoreTools.compare
        case .transfer: Copy.MoreTools.transfer
        }
    }

    var subtitle: String {
        switch self {
        case .camera: Copy.MoreTools.cameraDetail
        case .photos: Copy.MoreTools.photosDetail
        case .files: Copy.MoreTools.filesDetail
        case .manual: Copy.MoreTools.manualRecordDetail
        case .medication: Copy.MoreTools.medicationReminderDetail
        case .followUp: Copy.MoreTools.followUpReminderDetail
        case .calendar: Copy.MoreTools.systemCalendarDetail
        case .export: Copy.MoreTools.exportDetail
        case .compare: Copy.MoreTools.compareDetail
        case .transfer: Copy.MoreTools.transferDetail
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .photos: "photo.on.rectangle.angled"
        case .files: "folder.fill"
        case .manual: "square.and.pencil"
        case .medication: "pills.fill"
        case .followUp: "calendar.badge.clock"
        case .calendar: "calendar.badge.plus"
        case .export: "square.and.arrow.up"
        case .compare: "chart.xyaxis.line"
        case .transfer: "iphone.gen3.radiowaves.left.and.right"
        }
    }
}

struct MoreQuickActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCamera: () -> Void = {}
    var onPhotos: () -> Void = {}
    var onFiles: () -> Void = {}
    var onManualRecord: () -> Void = {}
    var onMedication: () -> Void = {}
    var onFollowUp: () -> Void = {}
    var onSystemCalendar: () -> Void = {}
    var onExport: () -> Void = {}
    var onCompare: () -> Void = {}
    var onTransfer: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Section(Copy.MoreTools.sourceSection) {
                    ForEach(MoreQuickAction.sourceActions) { value in
                        action(value)
                    }
                }
                Section(Copy.MoreTools.toolSection) {
                    ForEach(MoreQuickAction.toolActions) { value in
                        action(value)
                    }
                }
            }
            .listStyle(.insetGrouped)
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

    private func action(_ value: MoreQuickAction) -> some View {
        Button {
            dismiss()
            callback(for: value)()
        } label: {
            M4M5IconRow(
                title: value.title,
                subtitle: value.subtitle,
                systemImage: value.symbol
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("m45.more.\(value.rawValue)")
    }

    private func callback(for value: MoreQuickAction) -> () -> Void {
        switch value {
        case .camera: onCamera
        case .photos: onPhotos
        case .files: onFiles
        case .manual: onManualRecord
        case .medication: onMedication
        case .followUp: onFollowUp
        case .calendar: onSystemCalendar
        case .export: onExport
        case .compare: onCompare
        case .transfer: onTransfer
        }
    }
}
