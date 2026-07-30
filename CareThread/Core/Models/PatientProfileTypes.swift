import Foundation

enum CareQuestionStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case answered
}

/// A user-authored question or visit note. This value is part of the portable
/// patient profile payload, so identifiers and timestamps remain stable across
/// backup and nearby-device migration.
struct CareQuestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var status: CareQuestionStatus
    var answer: String?
    var note: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        status: CareQuestionStatus = .pending,
        answer: String? = nil,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.answer = answer
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

enum PatientProfileValidationError: Error, Equatable, LocalizedError {
    case displayNameRequired
    case displayNameTooLong
    case reportNameTooLong
    case genderTooLong
    case tooManyAliases
    case aliasTooLong
    case duplicateAlias
    case birthDateInFuture
    case tooManyConditions
    case conditionTooLong
    case tooManyAllergies
    case allergyTooLong
    case tooManyHistories
    case historyYearOutOfRange
    case historyTextRequired
    case historyTextTooLong
    case tooManyQuestions
    case duplicateQuestionID
    case questionRequired
    case questionTooLong
    case answerTooLong
    case noteTooLong
    case answeredQuestionNeedsAnswerOrNote
    case timestampOrderInvalid

    var errorDescription: String? {
        switch self {
        case .displayNameRequired:
            "成员称呼不能为空。"
        case .displayNameTooLong:
            "成员称呼最多 64 个字符。"
        case .reportNameTooLong:
            "报告姓名最多 64 个字符。"
        case .genderTooLong:
            "性别说明最多 32 个字符。"
        case .tooManyAliases:
            "姓名别名最多 20 个。"
        case .aliasTooLong:
            "每个姓名别名最多 64 个字符。"
        case .duplicateAlias:
            "姓名别名不能重复。"
        case .birthDateInFuture:
            "出生日期不能晚于今天。"
        case .tooManyConditions:
            "主要情况最多 64 项。"
        case .conditionTooLong:
            "每项主要情况最多 256 个字符。"
        case .tooManyAllergies:
            "过敏信息最多 64 项。"
        case .allergyTooLong:
            "每项过敏信息最多 256 个字符。"
        case .tooManyHistories:
            "重要病史最多 64 项。"
        case .historyYearOutOfRange:
            "病史年份应在 1900 年至明年之间。"
        case .historyTextRequired:
            "病史内容不能为空。"
        case .historyTextTooLong:
            "每项病史最多 512 个字符。"
        case .tooManyQuestions:
            "问医生的问题和就诊笔记最多 100 条。"
        case .duplicateQuestionID:
            "问题标识重复，未保存更改。"
        case .questionRequired:
            "问题内容不能为空。"
        case .questionTooLong:
            "问题最多 512 个字符。"
        case .answerTooLong:
            "回答最多 2048 个字符。"
        case .noteTooLong:
            "就诊笔记最多 2048 个字符。"
        case .answeredQuestionNeedsAnswerOrNote:
            "标记为已回答前，请填写回答或就诊笔记。"
        case .timestampOrderInvalid:
            "问题更新时间不能早于创建时间。"
        }
    }
}

enum PatientProfilePolicy {
    static let maximumNameCharacters = 64
    static let maximumGenderCharacters = 32
    static let maximumAliases = 20
    static let maximumListItems = 64
    static let maximumQuestions = 100
    static let maximumListItemCharacters = 256
    static let maximumHistoryCharacters = 512
    static let maximumQuestionCharacters = 512
    static let maximumAnswerOrNoteCharacters = 2_048

    static func validateIdentity(
        displayName: String,
        reportName: String?,
        aliases: [String],
        birthDate: Date?,
        gender: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        let displayName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !displayName.isEmpty else {
            throw PatientProfileValidationError.displayNameRequired
        }
        guard displayName.count <= maximumNameCharacters else {
            throw PatientProfileValidationError.displayNameTooLong
        }
        if let reportName = MemberIdentity.optionalTrimmed(reportName),
           reportName.count > maximumNameCharacters {
            throw PatientProfileValidationError.reportNameTooLong
        }
        if let gender = MemberIdentity.optionalTrimmed(gender),
           gender.count > maximumGenderCharacters {
            throw PatientProfileValidationError.genderTooLong
        }
        guard aliases.count <= maximumAliases else {
            throw PatientProfileValidationError.tooManyAliases
        }
        let trimmedAliases = aliases.compactMap(MemberIdentity.optionalTrimmed)
        guard trimmedAliases.count == aliases.count,
              trimmedAliases.allSatisfy({
                  $0.count <= maximumNameCharacters
              }) else {
            throw PatientProfileValidationError.aliasTooLong
        }
        let normalized = trimmedAliases.map(MemberIdentity.normalize)
        guard Set(normalized).count == normalized.count else {
            throw PatientProfileValidationError.duplicateAlias
        }
        if let birthDate,
           calendar.startOfDay(for: birthDate)
            > calendar.startOfDay(for: now) {
            throw PatientProfileValidationError.birthDateInFuture
        }
    }

    static func validateHealthLists(
        conditions: [String],
        allergies: [String],
        histories: [HistoryItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard conditions.count <= maximumListItems else {
            throw PatientProfileValidationError.tooManyConditions
        }
        guard conditions.allSatisfy({
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty
                && value.count <= maximumListItemCharacters
        }) else {
            throw PatientProfileValidationError.conditionTooLong
        }
        guard allergies.count <= maximumListItems else {
            throw PatientProfileValidationError.tooManyAllergies
        }
        guard allergies.allSatisfy({
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty
                && value.count <= maximumListItemCharacters
        }) else {
            throw PatientProfileValidationError.allergyTooLong
        }
        guard histories.count <= maximumListItems else {
            throw PatientProfileValidationError.tooManyHistories
        }
        let nextYear = calendar.component(.year, from: now) + 1
        for history in histories {
            guard (1900...nextYear).contains(history.year) else {
                throw PatientProfileValidationError.historyYearOutOfRange
            }
            let text = history.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                throw PatientProfileValidationError.historyTextRequired
            }
            guard text.count <= maximumHistoryCharacters else {
                throw PatientProfileValidationError.historyTextTooLong
            }
        }
    }

    static func validateQuestions(_ questions: [CareQuestion]) throws {
        guard questions.count <= maximumQuestions else {
            throw PatientProfileValidationError.tooManyQuestions
        }
        guard Set(questions.map(\.id)).count == questions.count else {
            throw PatientProfileValidationError.duplicateQuestionID
        }
        for question in questions {
            let text = question.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                throw PatientProfileValidationError.questionRequired
            }
            guard text.count <= maximumQuestionCharacters else {
                throw PatientProfileValidationError.questionTooLong
            }
            if let answer = MemberIdentity.optionalTrimmed(question.answer),
               answer.count > maximumAnswerOrNoteCharacters {
                throw PatientProfileValidationError.answerTooLong
            }
            if let note = MemberIdentity.optionalTrimmed(question.note),
               note.count > maximumAnswerOrNoteCharacters {
                throw PatientProfileValidationError.noteTooLong
            }
            if question.status == .answered,
               MemberIdentity.optionalTrimmed(question.answer) == nil,
               MemberIdentity.optionalTrimmed(question.note) == nil {
                throw PatientProfileValidationError.answeredQuestionNeedsAnswerOrNote
            }
            guard question.updatedAt >= question.createdAt else {
                throw PatientProfileValidationError.timestampOrderInvalid
            }
        }
    }

    static func normalizedQuestions(
        _ questions: [CareQuestion]
    ) -> [CareQuestion] {
        questions.map { question in
            var result = question
            result.text = question.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            result.answer = MemberIdentity.optionalTrimmed(question.answer)
            result.note = MemberIdentity.optionalTrimmed(question.note)
            return result
        }
    }
}
