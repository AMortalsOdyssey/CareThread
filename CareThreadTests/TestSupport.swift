import Foundation
import SwiftData
@testable import CareThread

enum TestSupport {
    @MainActor
    static func container() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Patient.self,
            MedicalRecord.self,
            Attachment.self,
            Medication.self,
            MedicalOrder.self,
            FollowUp.self,
            CaptureDraft.self,
            configurations: configuration
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CareThreadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

