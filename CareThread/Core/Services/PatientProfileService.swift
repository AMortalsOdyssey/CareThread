import Foundation
import SwiftData

enum PatientProfileServiceError: Error, Equatable, LocalizedError {
    case questionNotFound
    case noChanges

    var errorDescription: String? {
        switch self {
        case .questionNotFound:
            "这条问题已不存在，请刷新后重试。"
        case .noChanges:
            "没有需要保存的更改。"
        }
    }
}

/// Single mutation boundary for profile and visit-question edits. All writes
/// use the shared revision CAS service and therefore append an auditable
/// revision without putting any health text in logs.
@MainActor
struct PatientProfileService {
    let context: ModelContext
    var now: () -> Date = Date.init

    @discardableResult
    func save(
        _ patient: Patient,
        content requested: PatientEditableContent,
        expectedRevision: Int
    ) throws -> ContentRevision {
        try validate(requested)
        let before = patient.editableContent()
        var content = requested
        content.displayName = content.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        content.reportName = MemberIdentity.optionalTrimmed(content.reportName)
        content.aliases = content.aliases.compactMap(
            MemberIdentity.optionalTrimmed
        )
        content.gender = MemberIdentity.optionalTrimmed(content.gender)
        content.conditions = normalizedNonEmpty(content.conditions)
        content.allergies = normalizedNonEmpty(content.allergies)
        content.histories = content.histories.map {
            HistoryItem(
                id: $0.id,
                year: $0.year,
                text: $0.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
        content.careQuestions = PatientProfilePolicy.normalizedQuestions(
            content.careQuestions
        )
        content.updatedAt = now()

        let keys = changedFieldKeys(before: before, after: content)
        guard !keys.isEmpty else {
            throw PatientProfileServiceError.noChanges
        }
        return try ContentRevisionService(context: context).edit(
            patient,
            content: content,
            changedFieldKeys: keys,
            source: .manual,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func addQuestion(
        to patient: Patient,
        text: String,
        answer: String? = nil,
        note: String? = nil,
        status: CareQuestionStatus = .pending,
        expectedRevision: Int
    ) throws -> ContentRevision {
        var content = patient.editableContent()
        let timestamp = now()
        content.careQuestions.append(
            CareQuestion(
                text: text,
                status: status,
                answer: answer,
                note: note,
                createdAt: timestamp
            )
        )
        return try save(
            patient,
            content: content,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func updateQuestion(
        on patient: Patient,
        id: UUID,
        text: String,
        answer: String?,
        note: String?,
        status: CareQuestionStatus,
        expectedRevision: Int
    ) throws -> ContentRevision {
        var content = patient.editableContent()
        guard let index = content.careQuestions.firstIndex(
            where: { $0.id == id }
        ) else {
            throw PatientProfileServiceError.questionNotFound
        }
        var question = content.careQuestions[index]
        question.text = text
        question.answer = answer
        question.note = note
        question.status = status
        question.updatedAt = now()
        content.careQuestions[index] = question
        return try save(
            patient,
            content: content,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func removeQuestion(
        from patient: Patient,
        id: UUID,
        expectedRevision: Int
    ) throws -> ContentRevision {
        var content = patient.editableContent()
        let beforeCount = content.careQuestions.count
        content.careQuestions.removeAll { $0.id == id }
        guard content.careQuestions.count != beforeCount else {
            throw PatientProfileServiceError.questionNotFound
        }
        return try save(
            patient,
            content: content,
            expectedRevision: expectedRevision
        )
    }

    /// Reconciles the pending questions edited in the brief screen while
    /// retaining stable IDs by position. Answered questions and their notes are
    /// never removed by this convenience editor.
    @discardableResult
    func replacePendingQuestions(
        on patient: Patient,
        texts: [String],
        expectedRevision: Int
    ) throws -> ContentRevision {
        var content = patient.editableContent()
        let timestamp = now()
        let oldPending = content.careQuestions.filter {
            $0.status == .pending
        }
        let answered = content.careQuestions.filter {
            $0.status == .answered
        }
        let requested = texts.compactMap(MemberIdentity.optionalTrimmed)
        let pending = requested.enumerated().map { index, text in
            if oldPending.indices.contains(index) {
                var value = oldPending[index]
                if value.text != text {
                    value.text = text
                    value.updatedAt = timestamp
                }
                return value
            }
            return CareQuestion(
                text: text,
                createdAt: timestamp
            )
        }
        content.careQuestions = (answered + pending).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        return try save(
            patient,
            content: content,
            expectedRevision: expectedRevision
        )
    }

    func history(for patient: Patient) throws -> [ContentRevision] {
        try ContentRevisionService(context: context).history(for: patient)
    }

    @discardableResult
    func undoLast(
        _ patient: Patient,
        expectedRevision: Int
    ) throws -> ContentRevision {
        try ContentRevisionService(context: context).undoLast(
            patient,
            expectedRevision: expectedRevision
        )
    }

    private func validate(
        _ content: PatientEditableContent
    ) throws {
        try PatientProfilePolicy.validateIdentity(
            displayName: content.displayName,
            reportName: content.reportName,
            aliases: content.aliases,
            birthDate: content.birthDate,
            gender: content.gender,
            now: now()
        )
        try PatientProfilePolicy.validateHealthLists(
            conditions: content.conditions,
            allergies: content.allergies,
            histories: content.histories,
            now: now()
        )
        try PatientProfilePolicy.validateQuestions(content.careQuestions)
    }

    private func normalizedNonEmpty(_ values: [String]) -> [String] {
        values.compactMap(MemberIdentity.optionalTrimmed)
    }

    private func changedFieldKeys(
        before: PatientEditableContent,
        after: PatientEditableContent
    ) -> [String] {
        var keys: [String] = []
        if before.displayName != after.displayName { keys.append("displayName") }
        if before.reportName != after.reportName { keys.append("reportName") }
        if before.aliases != after.aliases { keys.append("aliases") }
        if before.birthDate != after.birthDate { keys.append("birthDate") }
        if before.gender != after.gender { keys.append("gender") }
        if before.conditions != after.conditions { keys.append("conditions") }
        if before.allergies != after.allergies { keys.append("allergies") }
        if before.histories != after.histories { keys.append("histories") }
        if before.careQuestions != after.careQuestions {
            keys.append("careQuestions")
        }
        return keys
    }
}
