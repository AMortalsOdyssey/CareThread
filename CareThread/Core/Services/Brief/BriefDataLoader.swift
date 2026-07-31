import Foundation
import SwiftData

enum M7BriefDataLoaderError: Error, Equatable {
    case memberNotFound
    case recordLimitExceeded
}

/// SwiftData is kept at this boundary. Brief building, range selection and
/// comparisons consume immutable snapshots and remain deterministic.
@MainActor
struct M7BriefDataLoader {
    nonisolated static let fetchBatchSize = 200
    nonisolated static let maximumExportRecordCount = 5_000

    let context: ModelContext

    func load(
        patientID: UUID,
        questions: [String]? = nil
    ) throws -> BriefInput {
        var memberFetch = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == patientID }
        )
        memberFetch.fetchLimit = 1
        guard let patient = try context.fetch(memberFetch).first else {
            AppLog.data.warning(
                "Brief load rejected because member was not found"
            )
            throw M7BriefDataLoaderError.memberNotFound
        }

        let recordModels = try loadRecords(patientID: patientID)
        let medicationModels = try loadMedications(patientID: patientID)
        let followUpModels = try loadFollowUps(patientID: patientID)
        let records = recordModels.map {
            BriefRecordSnapshot(
                id: $0.id,
                patientID: $0.patientId,
                eventDate: $0.eventDate,
                title: $0.title,
                summary: $0.summary,
                type: $0.type,
                reviewStatus: $0.reviewStatus,
                isInBrief: $0.inBrief,
                abnormalFlags: $0.abnormalFlags,
                structuredFields: $0.structuredFields,
                measurements: $0.measurements.map {
                    BriefMeasurementSnapshot(
                        name: $0.displayName,
                        numericValue: $0.numericValue,
                        textualValue: $0.textualValue,
                        unit: $0.unit,
                        abnormalState: $0.abnormalState
                    )
                },
                tags: $0.tags.map {
                    BriefTagSnapshot(kind: $0.kind, value: $0.displayValue)
                },
                hospital: $0.hospital,
                doctor: $0.doctor,
                primaryDisease: $0.primaryDisease,
                isKeyRecord: $0.isKeyRecord
            )
        }
        let medications = medicationModels.map {
            BriefMedicationSnapshot(
                id: $0.id,
                patientID: $0.patientId,
                name: $0.name,
                doseValue: $0.doseValue,
                doseUnit: $0.doseUnit,
                frequency: $0.frequency,
                weeklyCount: $0.weeklyCount,
                startDate: $0.startDate,
                endDate: $0.endDate,
                lifecycleStatus: $0.lifecycleStatus
            )
        }
        let followUps = followUpModels.map {
            BriefFollowUpSnapshot(
                id: $0.id,
                patientID: $0.patientId,
                plannedDate: $0.plannedDate,
                items: $0.items,
                reason: $0.reason,
                status: $0.status
            )
        }
        AppLog.data.info(
            "Brief snapshots loaded for one member: \(records.count) records"
        )
        return BriefInput(
            member: BriefMemberSnapshot(
                id: patient.id,
                displayName: patient.displayName,
                birthDate: patient.birthDate,
                gender: patient.gender,
                conditions: patient.conditions,
                allergies: patient.allergies,
                histories: patient.histories
            ),
            records: records,
            medications: medications,
            followUps: followUps,
            questions: questions ?? patient.careQuestions
                .filter { $0.status == .pending }
                .sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt < $1.createdAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .map(\.text)
        )
    }

    nonisolated static func validateExportRecordCount(_ count: Int) throws {
        guard count >= 0, count <= maximumExportRecordCount else {
            throw M7BriefDataLoaderError.recordLimitExceeded
        }
    }

    private func loadRecords(patientID: UUID) throws -> [MedicalRecord] {
        var output: [MedicalRecord] = []
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<MedicalRecord>(
                predicate: #Predicate { $0.patientId == patientID },
                sortBy: [
                    SortDescriptor(\.eventDate, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
            descriptor.fetchLimit = Self.fetchBatchSize
            descriptor.fetchOffset = output.count
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            output.append(contentsOf: batch)
            try Self.validateExportRecordCount(output.count)
            guard batch.count == Self.fetchBatchSize else { break }
        }
        return output
    }

    private func loadMedications(patientID: UUID) throws -> [Medication] {
        var output: [Medication] = []
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Medication>(
                predicate: #Predicate { $0.patientId == patientID },
                sortBy: [
                    SortDescriptor(\.startDate, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
            descriptor.fetchLimit = Self.fetchBatchSize
            descriptor.fetchOffset = output.count
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            output.append(contentsOf: batch)
            guard batch.count == Self.fetchBatchSize else { break }
        }
        return output
    }

    private func loadFollowUps(patientID: UUID) throws -> [FollowUp] {
        var output: [FollowUp] = []
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<FollowUp>(
                predicate: #Predicate { $0.patientId == patientID },
                sortBy: [
                    SortDescriptor(\.plannedDate),
                    SortDescriptor(\.id)
                ]
            )
            descriptor.fetchLimit = Self.fetchBatchSize
            descriptor.fetchOffset = output.count
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            output.append(contentsOf: batch)
            guard batch.count == Self.fetchBatchSize else { break }
        }
        return output
    }
}
