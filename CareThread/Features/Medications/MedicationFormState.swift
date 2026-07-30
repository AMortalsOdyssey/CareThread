import Foundation

enum MedicationFormValidation: Equatable {
    case valid
    case missingName
    case invalidDose
    case endBeforeStart
    case invalidWeeklyCount
    case invalidReminderTimes

    var message: String? {
        switch self {
        case .valid: nil
        case .missingName: Copy.Medication.missingName
        case .invalidDose: Copy.Medication.invalidDose
        case .endBeforeStart: Copy.Medication.endBeforeStart
        case .invalidWeeklyCount: Copy.Medication.invalidWeeklyCount
        case .invalidReminderTimes: Copy.System.schedulingFailed
        }
    }
}

struct MedicationFormState: Equatable {
    var name = ""
    var doseText = ""
    var doseUnit = "mg"
    var frequency = FrequencyPreset.dailyOne
    var weeklyCount = 1
    var usageNotes: Set<String> = []
    var startDate: Date
    var isLongTerm = true
    var endDate: Date
    var hospital = ""
    var department = ""
    var linkedDiagnosis = ""
    var caution = ""
    var reminderEnabled = false
    var reminderTimes = ReminderPlanner.suggestedTimes(for: .dailyOne)
    var remainingQuantityText = ""
    var refillReminderEnabled = false
    var refillReminderAt: Date

    init(now: Date = Date()) {
        startDate = now
        endDate = Calendar.current.date(byAdding: .month, value: 1, to: now) ?? now
        refillReminderAt = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
    }

    init(medication: Medication, now: Date = Date()) {
        name = medication.name
        doseText = medication.doseValue.map {
            $0.formatted(.number.precision(.fractionLength(0...3)))
        } ?? ""
        doseUnit = medication.doseUnit
        frequency = medication.frequency
        weeklyCount = medication.weeklyCount ?? 1
        usageNotes = Set(medication.usageNotes)
        startDate = medication.startDate
        isLongTerm = medication.isLongTerm
        endDate = medication.endDate ??
            Calendar.current.date(byAdding: .month, value: 1, to: now) ?? now
        hospital = medication.hospital ?? ""
        department = medication.department ?? ""
        linkedDiagnosis = medication.linkedDiagnosis ?? ""
        caution = medication.caution ?? ""
        reminderEnabled = medication.reminderEnabled
        reminderTimes = medication.reminderTimes.isEmpty
            ? ReminderPlanner.suggestedTimes(for: medication.frequency)
            : medication.reminderTimes
        remainingQuantityText = medication.remainingQuantity.map {
            $0.formatted(.number.precision(.fractionLength(0...2)))
        } ?? ""
        refillReminderEnabled = medication.refillReminderAt != nil
        refillReminderAt = medication.refillReminderAt ??
            Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        normalizeSchedule()
    }

    var doseValue: Double? {
        Double(doseText.replacingOccurrences(of: ",", with: "."))
    }

    var remainingQuantity: Double? {
        guard !remainingQuantityText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Double(
            remainingQuantityText.replacingOccurrences(of: ",", with: ".")
        )
    }

    var validation: MedicationFormValidation {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingName
        }
        guard let doseValue, doseValue > 0, doseValue.isFinite else {
            return .invalidDose
        }
        if !isLongTerm, endDate < startDate {
            return .endBeforeStart
        }
        if frequency == .weekly, !(1...7).contains(weeklyCount) {
            return .invalidWeeklyCount
        }
        do {
            try FrequencySchedulePolicy.validate(
                frequency: frequency,
                weeklyCount: frequency == .weekly ? weeklyCount : nil,
                reminderEnabled: reminderEnabled,
                reminderTimes: reminderEnabled ? reminderTimes : []
            )
        } catch {
            return .invalidReminderTimes
        }
        return .valid
    }

    var canSave: Bool { validation == .valid }

    mutating func changeFrequency(to value: FrequencyPreset) {
        frequency = value
        if value == .asNeeded {
            reminderEnabled = false
            reminderTimes = []
        } else {
            reminderTimes = ReminderPlanner.suggestedTimes(for: value)
        }
    }

    mutating func setReminderEnabled(_ enabled: Bool) {
        reminderEnabled = enabled && frequency != .asNeeded
        if reminderEnabled {
            reminderTimes = ReminderPlanner.suggestedTimes(for: frequency)
        }
    }

    mutating func normalizeSchedule() {
        if frequency == .asNeeded {
            reminderEnabled = false
            reminderTimes = []
        } else if reminderEnabled &&
                    reminderTimes.count != FrequencySchedulePolicy
                        .expectedReminderTimeCount(for: frequency) {
            reminderTimes = ReminderPlanner.suggestedTimes(for: frequency)
        }
    }

    func draft(patientID: UUID) -> MedicationDraft? {
        guard canSave, let doseValue else { return nil }
        return MedicationDraft(
            patientId: patientID,
            name: name,
            doseValue: doseValue,
            doseUnit: doseUnit,
            frequency: frequency,
            weeklyCount: frequency == .weekly ? weeklyCount : nil,
            usageNotes: Copy.Medication.usageOptions.filter(usageNotes.contains),
            startDate: startDate,
            endDate: isLongTerm ? nil : endDate,
            isLongTerm: isLongTerm,
            hospital: nilIfEmpty(hospital),
            department: nilIfEmpty(department),
            linkedDiagnosis: nilIfEmpty(linkedDiagnosis),
            caution: nilIfEmpty(caution),
            reminderEnabled: reminderEnabled,
            reminderTimes: reminderEnabled ? reminderTimes : [],
            remainingQuantity: remainingQuantity,
            refillReminderAt: refillReminderEnabled ? refillReminderAt : nil
        )
    }

    func editableContent(
        from medication: Medication,
        updatedAt: Date
    ) -> MedicationEditableContent? {
        guard canSave, let doseValue else { return nil }
        var value = medication.editableContent()
        value.name = name
        value.doseValue = doseValue
        value.doseUnit = doseUnit
        value.frequency = frequency
        value.weeklyCount = frequency == .weekly ? weeklyCount : nil
        value.usageNotes = Copy.Medication.usageOptions.filter(usageNotes.contains)
        value.startDate = startDate
        value.endDate = isLongTerm ? nil : endDate
        value.isLongTerm = isLongTerm
        value.hospital = nilIfEmpty(hospital)
        value.department = nilIfEmpty(department)
        value.linkedDiagnosis = nilIfEmpty(linkedDiagnosis)
        value.caution = nilIfEmpty(caution)
        value.reminderEnabled = reminderEnabled
        value.reminderTimes = reminderEnabled ? reminderTimes : []
        value.remainingQuantity = remainingQuantity
        value.refillReminderAt = refillReminderEnabled ? refillReminderAt : nil
        value.updatedAt = updatedAt
        return value
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct OrderFollowUpPrefill: Equatable {
    var plannedDate: Date
    var item: String
    var reason: String

    static func make(
        orderText: String,
        now: Date,
        calendar: Calendar = .current
    ) -> OrderFollowUpPrefill {
        let normalized = orderText.trimmingCharacters(in: .whitespacesAndNewlines)
        let monthCount = parsedMonthCount(from: normalized) ?? 3
        let date = calendar.date(
            byAdding: .month,
            value: monthCount,
            to: now
        ) ?? now
        let item: String
        if let range = normalized.range(of: "复查") {
            let suffix = normalized[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            item = suffix.isEmpty ? normalized : suffix
        } else {
            item = normalized
        }
        return OrderFollowUpPrefill(
            plannedDate: date,
            item: item,
            reason: normalized
        )
    }

    private static func parsedMonthCount(from text: String) -> Int? {
        let pattern = #"([0-9]+)\s*个?\s*月后"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }
}
