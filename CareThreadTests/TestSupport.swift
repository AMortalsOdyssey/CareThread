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

    static func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: FixtureBundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "txt") ??
                bundle.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class FixtureBundleToken: NSObject {}

enum FixtureError: Error {
    case missing(String)
}
