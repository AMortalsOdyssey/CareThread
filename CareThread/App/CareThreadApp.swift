import SwiftUI
import SwiftData

@main
struct CareThreadApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(
            for: [
                Patient.self,
                MedicalRecord.self,
                Attachment.self,
                Medication.self,
                MedicalOrder.self,
                FollowUp.self,
                CaptureDraft.self
            ]
        )
    }
}
