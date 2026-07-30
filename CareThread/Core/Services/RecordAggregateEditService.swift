import Foundation
import SwiftData

enum RecordAggregateEditError: Error, Equatable {
    case noChanges
    case revisionConflict(expected: Int, actual: Int)
    case payloadEncodingFailed
    case immutableField(String)
    case invalidValue(String)
    case crossPatientScope
    case invalidGraph
    case databaseSaveFailed
}

/// A complete user-editable snapshot of one laboratory measurement.
///
/// The stable id lets the aggregate service distinguish an edit from an
/// insertion without exposing the immutable record/member relationship.
struct RecordMeasurementEdit: Equatable, Identifiable {
    let id: UUID
    var content: LabMeasurementEditableContent

    init(id: UUID = UUID(), content: LabMeasurementEditableContent) {
        self.id = id
        self.content = content
    }

    init(_ measurement: LabMeasurement) {
        id = measurement.id
        content = measurement.editableContent()
    }
}

/// Saves the user-editable MedicalRecord fields and its disease-tag
/// and laboratory-measurement relationships as one aggregate transaction.
///
/// The caller must capture `expectedRevision` when the edit form opens. A
/// fresh-context revision probe prevents a stale form from overwriting a save
/// made by another scene/context. Disease values are normalized and de-duped;
/// the first value is the primary disease and is never duplicated as a tag.
/// A nil `measurementEdits` preserves the existing measurement graph, while an
/// empty array explicitly removes every measurement.
@MainActor
final class RecordAggregateEditService {
    typealias SaveAction = @MainActor (ModelContext) throws -> Void

    private let context: ModelContext
    private let saveAction: SaveAction
    private let now: @MainActor () -> Date

    init(
        context: ModelContext,
        saveAction: @escaping SaveAction = { try $0.save() },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.context = context
        self.saveAction = saveAction
        self.now = now
    }

    @discardableResult
    func save(
        record: MedicalRecord,
        content requestedContent: MedicalRecordEditableContent,
        diseaseValues: [String],
        measurementEdits: [RecordMeasurementEdit]? = nil,
        changedFieldKeys: [String],
        expectedRevision: Int
    ) throws -> ContentRevision {
        let actualRevision = try persistedRevision(recordID: record.id)
        guard actualRevision == expectedRevision,
              record.contentRevision == expectedRevision else {
            AppLog.data.warning(
                "Rejected stale medical-record aggregate edit \(record.id.uuidString, privacy: .private(mask: .hash))"
            )
            throw RecordAggregateEditError.revisionConflict(
                expected: expectedRevision,
                actual: actualRevision
            )
        }

        try validatePatientScope(record)
        let beforeContent = record.editableContent()
        guard requestedContent.confirmedRevision ==
                beforeContent.confirmedRevision else {
            throw RecordAggregateEditError.immutableField(
                "confirmedRevision"
            )
        }
        guard requestedContent.confirmedAt == beforeContent.confirmedAt else {
            throw RecordAggregateEditError.immutableField("confirmedAt")
        }

        let diseases = Self.normalizedDiseaseValues(diseaseValues)
        try validateDiseaseValues(diseases)
        var content = try normalizedRecordContent(requestedContent)
        content.primaryDisease = diseases.first
        let requestedTagValues = Array(diseases.dropFirst())
        // updatedAt is a system field, not a reason by itself to create a
        // revision. Compare business content first, then stamp the transaction.
        content.updatedAt = beforeContent.updatedAt
        let beforeRevision = record.contentRevision
        let beforeTags = record.tags
        let beforeMeasurements = record.measurements
        let beforeMeasurementContents = Dictionary(
            uniqueKeysWithValues: beforeMeasurements.map {
                ($0.id, $0.editableContent())
            }
        )
        let beforeMeasurementRevisions = Dictionary(
            uniqueKeysWithValues: beforeMeasurements.map {
                ($0.id, $0.contentRevision)
            }
        )
        let existingDiseaseValues = record.tags
            .filter { $0.kind == .disease }
            .map(\.displayValue)
            .sorted()
        let requestedDiseaseValues = requestedTagValues
            .sorted()
        let recordChanged = beforeContent != content
        let tagsChanged = existingDiseaseValues != requestedDiseaseValues
        let preparedMeasurements = try prepareMeasurements(
            record: record,
            requested: measurementEdits
        )
        let measurementsChanged = measurementEdits != nil &&
            !measurementSnapshotsEqual(
                beforeMeasurementContents,
                preparedMeasurements.contentsByID
            )
        guard recordChanged || tagsChanged || measurementsChanged else {
            throw RecordAggregateEditError.noChanges
        }
        content.updatedAt = now()

        let replacementTags = makeReplacementTags(
            record: record,
            requestedDiseaseValues: requestedTagValues
        )
        let automaticallyChangedKeys = Self.changedRecordFieldKeys(
            before: beforeContent,
            after: content
        )
        let relationKeys =
            (tagsChanged ? ["diseaseTags"] : [])
            + (measurementsChanged ? ["labMeasurements"] : [])
        let exactKeys = automaticallyChangedKeys + relationKeys
        // A caller may provide hints for compatibility, but the audit stores
        // only fields proven changed by the normalized transaction.
        let keys = Array(
            Set(
                exactKeys + changedFieldKeys.filter {
                    exactKeys.contains($0)
                }
            )
        ).sorted()

        do {
            record.applyEditableContent(content)
            let removedTags = try record.replaceTags(with: replacementTags)
            let removedMeasurements = try record.replaceMeasurements(
                with: preparedMeasurements.values
            )
            try record.validateGraph()
            let measurementRevisions = try makeMeasurementRevisions(
                replacements: preparedMeasurements.values,
                removed: removedMeasurements,
                beforeContents: beforeMeasurementContents,
                requestedContents: preparedMeasurements.contentsByID
            )
            removedTags.forEach(context.delete)
            removedMeasurements.forEach(context.delete)
            record.bumpContentRevision()
            let beforePayload = try ModelPayload.encode(beforeContent)
            let afterPayload = try ModelPayload.encode(
                record.editableContent()
            )
            let revision = ContentRevision(
                entityKind: .medicalRecord,
                entityId: record.id,
                patientId: record.patientId,
                revision: record.contentRevision,
                changedFieldKeys: keys,
                beforeContentPayload: beforePayload,
                afterContentPayload: afterPayload,
                source: .manual
            )
            context.insert(revision)
            measurementRevisions.forEach(context.insert)
            try saveAction(context)
            AppLog.userAction.info(
                "Saved medical-record aggregate \(record.id.uuidString, privacy: .private(mask: .hash)), measurements \(preparedMeasurements.values.count, privacy: .private)"
            )
            return revision
        } catch let error as RecordAggregateEditError {
            restore(
                record: record,
                content: beforeContent,
                revision: beforeRevision,
                tags: beforeTags,
                measurements: beforeMeasurements,
                measurementContents: beforeMeasurementContents,
                measurementRevisions: beforeMeasurementRevisions
            )
            throw error
        } catch let error as RecordGraphValidationError {
            restore(
                record: record,
                content: beforeContent,
                revision: beforeRevision,
                tags: beforeTags,
                measurements: beforeMeasurements,
                measurementContents: beforeMeasurementContents,
                measurementRevisions: beforeMeasurementRevisions
            )
            AppLog.data.error(
                "Medical-record aggregate graph validation failed: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            throw RecordAggregateEditError.invalidGraph
        } catch {
            restore(
                record: record,
                content: beforeContent,
                revision: beforeRevision,
                tags: beforeTags,
                measurements: beforeMeasurements,
                measurementContents: beforeMeasurementContents,
                measurementRevisions: beforeMeasurementRevisions
            )
            AppLog.data.error(
                "Medical-record aggregate save failed: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            throw RecordAggregateEditError.databaseSaveFailed
        }
    }

    static func normalizedDiseaseValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let trimmed = MemberIdentity.optionalTrimmed(value) else {
                continue
            }
            let normalized = MemberIdentity.normalize(trimmed)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }

    static func changedRecordFieldKeys(
        before: MedicalRecordEditableContent,
        after: MedicalRecordEditableContent
    ) -> [String] {
        var keys: [String] = []
        if before.type != after.type { keys.append("type") }
        if before.title != after.title { keys.append("title") }
        if before.summary != after.summary { keys.append("summary") }
        if before.eventDate != after.eventDate { keys.append("eventDate") }
        if before.eventDatePrecision != after.eventDatePrecision {
            keys.append("eventDatePrecision")
        }
        if before.eventTimezoneIdentifier != after.eventTimezoneIdentifier {
            keys.append("eventTimezoneIdentifier")
        }
        if before.hospital != after.hospital { keys.append("hospital") }
        if before.department != after.department {
            keys.append("department")
        }
        if before.doctor != after.doctor { keys.append("doctor") }
        if before.primaryDisease != after.primaryDisease {
            keys.append("primaryDisease")
        }
        if before.ageAtEvent != after.ageAtEvent {
            keys.append("ageAtEvent")
        }
        if before.abnormalFlags != after.abnormalFlags {
            keys.append("abnormalFlags")
        }
        if before.structuredFields != after.structuredFields {
            keys.append("structuredFields")
        }
        if before.reviewStatus != after.reviewStatus {
            keys.append("reviewStatus")
        }
        if before.isKeyRecord != after.isKeyRecord {
            keys.append("isKeyRecord")
        }
        if before.inBrief != after.inBrief { keys.append("inBrief") }
        return keys
    }

    private struct PreparedMeasurements {
        let values: [LabMeasurement]
        let contentsByID: [UUID: LabMeasurementEditableContent]
    }

    private func normalizedRecordContent(
        _ requested: MedicalRecordEditableContent
    ) throws -> MedicalRecordEditableContent {
        var content = requested
        content.title = requested.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        content.summary = requested.summary.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        content.hospital = MemberIdentity.optionalTrimmed(requested.hospital)
        content.department = MemberIdentity.optionalTrimmed(
            requested.department
        )
        content.doctor = MemberIdentity.optionalTrimmed(requested.doctor)
        content.primaryDisease = MemberIdentity.optionalTrimmed(
            requested.primaryDisease
        )
        content.abnormalFlags = Self.normalizedTextValues(
            requested.abnormalFlags
        )
        content.structuredFields = requested.structuredFields.map {
            KeyValueItem(
                id: $0.id,
                key: $0.key.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                value: $0.value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }

        guard !content.title.isEmpty else {
            throw RecordAggregateEditError.invalidValue("title")
        }
        try validateText(
            content.title,
            maximum: DomainFieldPolicy.shortTextMaximumUTF8Bytes,
            field: "title"
        )
        try validateText(
            content.summary,
            maximum: DomainFieldPolicy.noteMaximumUTF8Bytes,
            field: "summary"
        )
        for (value, field) in [
            (content.hospital, "hospital"),
            (content.department, "department"),
            (content.doctor, "doctor")
        ] {
            if let value {
                try validateText(
                    value,
                    maximum: DomainFieldPolicy.shortTextMaximumUTF8Bytes,
                    field: field
                )
            }
        }
        guard DomainFieldPolicy.isFinite(content.eventDate),
              TimeZone(identifier: content.eventTimezoneIdentifier) != nil else {
            throw RecordAggregateEditError.invalidValue("eventDate")
        }
        if let age = content.ageAtEvent, !(0...130).contains(age) {
            throw RecordAggregateEditError.invalidValue("ageAtEvent")
        }
        try validateList(
            content.abnormalFlags,
            field: "abnormalFlags",
            itemMaximum: DomainFieldPolicy.listItemMaximumUTF8Bytes
        )
        guard content.structuredFields.count <=
                DomainFieldPolicy.listMaximumCount else {
            throw RecordAggregateEditError.invalidValue("structuredFields")
        }
        var structuredKeys = Set<String>()
        for field in content.structuredFields {
            guard !field.key.isEmpty else {
                throw RecordAggregateEditError.invalidValue(
                    "structuredFields.key"
                )
            }
            try validateText(
                field.key,
                maximum: DomainFieldPolicy.shortTextMaximumUTF8Bytes,
                field: "structuredFields.key"
            )
            try validateText(
                field.value,
                maximum: DomainFieldPolicy.noteMaximumUTF8Bytes,
                field: "structuredFields.value"
            )
            guard structuredKeys.insert(
                MemberIdentity.normalize(field.key)
            ).inserted else {
                throw RecordAggregateEditError.invalidValue(
                    "structuredFields.duplicateKey"
                )
            }
        }
        return content
    }

    private func prepareMeasurements(
        record: MedicalRecord,
        requested: [RecordMeasurementEdit]?
    ) throws -> PreparedMeasurements {
        guard let requested else {
            return PreparedMeasurements(
                values: record.measurements,
                contentsByID: Dictionary(
                    uniqueKeysWithValues: record.measurements.map {
                        ($0.id, $0.editableContent())
                    }
                )
            )
        }
        guard requested.count <= DomainFieldPolicy.listMaximumCount,
              Set(requested.map(\.id)).count == requested.count else {
            throw RecordAggregateEditError.invalidValue("labMeasurements")
        }
        let existing = Dictionary(
            uniqueKeysWithValues: record.measurements.map { ($0.id, $0) }
        )
        var values: [LabMeasurement] = []
        var contents: [UUID: LabMeasurementEditableContent] = [:]
        values.reserveCapacity(requested.count)

        for input in requested {
            let normalized = try normalizedMeasurementContent(input.content)
            contents[input.id] = normalized
            if let value = existing[input.id] {
                values.append(value)
                continue
            }
            if let other = try fetchMeasurement(id: input.id) {
                AppLog.data.warning(
                    "Rejected cross-record measurement \(other.id.uuidString, privacy: .private(mask: .hash))"
                )
                throw RecordAggregateEditError.crossPatientScope
            }
            values.append(
                LabMeasurement(
                    id: input.id,
                    patientId: record.patientId,
                    recordId: record.id,
                    displayName: normalized.displayName,
                    numericValue: normalized.numericValue,
                    textualValue: normalized.textualValue,
                    unit: normalized.unit,
                    referenceLow: normalized.referenceLow,
                    referenceHigh: normalized.referenceHigh,
                    referenceText: normalized.referenceText,
                    abnormalState: normalized.abnormalState,
                    confidence: normalized.confidence,
                    eventDate: normalized.eventDate
                )
            )
        }
        return PreparedMeasurements(values: values, contentsByID: contents)
    }

    private func normalizedMeasurementContent(
        _ requested: LabMeasurementEditableContent
    ) throws -> LabMeasurementEditableContent {
        var content = requested
        content.displayName = requested.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        content.textualValue = MemberIdentity.optionalTrimmed(
            requested.textualValue
        )
        content.unit = requested.unit.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        content.referenceText = MemberIdentity.optionalTrimmed(
            requested.referenceText
        )
        guard !content.displayName.isEmpty else {
            throw RecordAggregateEditError.invalidValue(
                "labMeasurement.displayName"
            )
        }
        try validateText(
            content.displayName,
            maximum: DomainFieldPolicy.shortTextMaximumUTF8Bytes,
            field: "labMeasurement.displayName"
        )
        try validateText(
            content.unit,
            maximum: DomainFieldPolicy.unitMaximumUTF8Bytes,
            field: "labMeasurement.unit"
        )
        if let value = content.textualValue {
            try validateText(
                value,
                maximum: DomainFieldPolicy.listItemMaximumUTF8Bytes,
                field: "labMeasurement.textualValue"
            )
        }
        if let value = content.referenceText {
            try validateText(
                value,
                maximum: DomainFieldPolicy.listItemMaximumUTF8Bytes,
                field: "labMeasurement.referenceText"
            )
        }
        guard content.numericValue.map(\.isFinite) ?? true,
              content.referenceLow.map(\.isFinite) ?? true,
              content.referenceHigh.map(\.isFinite) ?? true,
              DomainFieldPolicy.isFinite(content.eventDate) else {
            throw RecordAggregateEditError.invalidValue(
                "labMeasurement.numberOrDate"
            )
        }
        guard content.numericValue != nil || content.textualValue != nil else {
            throw RecordAggregateEditError.invalidValue(
                "labMeasurement.value"
            )
        }
        if let low = content.referenceLow,
           let high = content.referenceHigh,
           low > high {
            throw RecordAggregateEditError.invalidValue(
                "labMeasurement.referenceRange"
            )
        }
        return content
    }

    private func makeMeasurementRevisions(
        replacements: [LabMeasurement],
        removed: [LabMeasurement],
        beforeContents: [UUID: LabMeasurementEditableContent],
        requestedContents: [UUID: LabMeasurementEditableContent]
    ) throws -> [ContentRevision] {
        var revisions: [ContentRevision] = []
        for measurement in replacements {
            guard let requested = requestedContents[measurement.id] else {
                throw RecordAggregateEditError.invalidGraph
            }
            if let before = beforeContents[measurement.id] {
                // Applying the requested snapshot also restores an explicitly
                // independent measurement date after MedicalRecord updates its
                // own event date.
                measurement.applyEditableContent(requested)
                guard before != requested else { continue }
                measurement.bumpContentRevision()
                revisions.append(
                    try measurementRevision(
                        measurement: measurement,
                        before: before,
                        after: measurement.editableContent(),
                        changedKeys: Self.changedMeasurementFieldKeys(
                            before: before,
                            after: requested
                        )
                    )
                )
            } else {
                measurement.applyEditableContent(requested)
                measurement.bumpContentRevision()
                let after = measurement.editableContent()
                revisions.append(
                    try measurementRevision(
                        measurement: measurement,
                        before: after,
                        after: after,
                        changedKeys: ["created"]
                    )
                )
            }
        }
        for measurement in removed {
            let before = beforeContents[measurement.id] ??
                measurement.editableContent()
            measurement.bumpContentRevision()
            revisions.append(
                try measurementRevision(
                    measurement: measurement,
                    before: before,
                    after: before,
                    changedKeys: ["deleted"]
                )
            )
        }
        return revisions
    }

    private func measurementRevision(
        measurement: LabMeasurement,
        before: LabMeasurementEditableContent,
        after: LabMeasurementEditableContent,
        changedKeys: [String]
    ) throws -> ContentRevision {
        do {
            return ContentRevision(
                entityKind: .labMeasurement,
                entityId: measurement.id,
                patientId: measurement.patientId,
                revision: measurement.contentRevision,
                changedFieldKeys: changedKeys,
                beforeContentPayload: try ModelPayload.encode(before),
                afterContentPayload: try ModelPayload.encode(after),
                source: .manual
            )
        } catch {
            throw RecordAggregateEditError.payloadEncodingFailed
        }
    }

    private static func changedMeasurementFieldKeys(
        before: LabMeasurementEditableContent,
        after: LabMeasurementEditableContent
    ) -> [String] {
        var keys: [String] = []
        if before.displayName != after.displayName {
            keys.append("displayName")
        }
        if before.numericValue != after.numericValue {
            keys.append("numericValue")
        }
        if before.textualValue != after.textualValue {
            keys.append("textualValue")
        }
        if before.unit != after.unit { keys.append("unit") }
        if before.referenceLow != after.referenceLow {
            keys.append("referenceLow")
        }
        if before.referenceHigh != after.referenceHigh {
            keys.append("referenceHigh")
        }
        if before.referenceText != after.referenceText {
            keys.append("referenceText")
        }
        if before.abnormalState != after.abnormalState {
            keys.append("abnormalState")
        }
        if before.confidence != after.confidence {
            keys.append("confidence")
        }
        if before.eventDate != after.eventDate {
            keys.append("eventDate")
        }
        return keys
    }

    private func validatePatientScope(_ record: MedicalRecord) throws {
        let id = record.patientId
        var descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).first != nil else {
            throw RecordAggregateEditError.crossPatientScope
        }
    }

    private func validateDiseaseValues(_ values: [String]) throws {
        try validateList(
            values,
            field: "diseaseValues",
            itemMaximum: DomainFieldPolicy.shortTextMaximumUTF8Bytes
        )
    }

    private func validateList(
        _ values: [String],
        field: String,
        itemMaximum: Int
    ) throws {
        guard values.count <= DomainFieldPolicy.listMaximumCount,
              values.allSatisfy({
                  DomainFieldPolicy.isWithinUTF8Limit(
                      $0,
                      maximum: itemMaximum
                  )
              }) else {
            throw RecordAggregateEditError.invalidValue(field)
        }
    }

    private func validateText(
        _ value: String,
        maximum: Int,
        field: String
    ) throws {
        guard DomainFieldPolicy.isWithinUTF8Limit(
            value,
            maximum: maximum
        ) else {
            throw RecordAggregateEditError.invalidValue(field)
        }
    }

    private static func normalizedTextValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            guard let trimmed = MemberIdentity.optionalTrimmed($0) else {
                return nil
            }
            let normalized = MemberIdentity.normalize(trimmed)
            return seen.insert(normalized).inserted ? trimmed : nil
        }
    }

    private func measurementSnapshotsEqual(
        _ lhs: [UUID: LabMeasurementEditableContent],
        _ rhs: [UUID: LabMeasurementEditableContent]
    ) -> Bool {
        lhs == rhs
    }

    private func makeReplacementTags(
        record: MedicalRecord,
        requestedDiseaseValues: [String]
    ) -> [RecordTag] {
        var result = record.tags.filter { $0.kind != .disease }
        var existingByValue: [String: [RecordTag]] = [:]
        for tag in record.tags
            .filter({ $0.kind == .disease })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            existingByValue[
                MemberIdentity.normalize(tag.displayValue),
                default: []
            ].append(tag)
        }
        for value in requestedDiseaseValues {
            let normalized = MemberIdentity.normalize(value)
            if let existing = existingByValue[normalized]?.first,
               existing.displayValue == value {
                result.append(existing)
            } else {
                result.append(
                    RecordTag(
                        patientId: record.patientId,
                        recordId: record.id,
                        kind: .disease,
                        displayValue: value
                    )
                )
            }
        }
        return result
    }

    private func fetchMeasurement(id: UUID) throws -> LabMeasurement? {
        var descriptor = FetchDescriptor<LabMeasurement>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func persistedRevision(recordID: UUID) throws -> Int {
        let probe = ModelContext(context.container)
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        guard let persisted = try probe.fetch(descriptor).first else {
            throw RecordAggregateEditError.databaseSaveFailed
        }
        return persisted.contentRevision
    }

    private func restore(
        record: MedicalRecord,
        content: MedicalRecordEditableContent,
        revision: Int,
        tags: [RecordTag],
        measurements: [LabMeasurement],
        measurementContents: [UUID: LabMeasurementEditableContent],
        measurementRevisions: [UUID: Int]
    ) {
        context.rollback()
        record.applyEditableContent(content)
        record.restoreContentRevision(revision)
        _ = try? record.replaceTags(with: tags)
        for measurement in measurements {
            if let value = measurementContents[measurement.id] {
                measurement.applyEditableContent(value)
            }
            if let value = measurementRevisions[measurement.id] {
                measurement.restoreContentRevision(value)
            }
        }
        _ = try? record.replaceMeasurements(with: measurements)
    }
}
