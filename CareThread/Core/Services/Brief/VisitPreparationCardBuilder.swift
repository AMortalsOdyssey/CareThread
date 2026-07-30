import Foundation

enum VisitPreparationCardBuilder {
    static func build(
        input: BriefInput,
        contact: String? = nil,
        selection: VisitPreparationSelection = VisitPreparationSelection(),
        generatedAt: Date,
        calendar: Calendar = CTDate.calendar
    ) -> VisitPreparationCardDocument {
        let memberID = input.member.id
        let records = input.records
            .filter {
                $0.patientID == memberID && $0.reviewStatus == .confirmed
            }
            .sorted(by: recordOrder)
        let medications = input.medications
            .filter {
                $0.patientID == memberID && $0.isCurrent(at: generatedAt)
            }
            .sorted {
                if $0.startDate != $1.startDate {
                    return $0.startDate > $1.startDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        let selectedRecordIDs = selection.selectedRecordIDs
            ?? Set(
                records
                    .filter { $0.isKeyRecord || $0.isInBrief }
                    .map(\.id)
            )

        var omittedCount = 0
        var shortenedCount = 0
        var remainingCapacity = VisitPreparationCardPolicy.maximumVisibleItems
        var sections: [VisitPreparationCardSection] = []

        for sectionID in VisitPreparationSectionID.allCases {
            guard selection.enabledSections.contains(sectionID) else {
                continue
            }
            let candidates = candidateItems(
                for: sectionID,
                input: input,
                records: records,
                medications: medications,
                selectedRecordIDs: selectedRecordIDs,
                contact: contact,
                generatedAt: generatedAt,
                calendar: calendar
            )
            let sectionCapacity = min(
                VisitPreparationCardPolicy.itemLimit(for: sectionID),
                max(0, remainingCapacity)
            )
            let visible = Array(candidates.prefix(sectionCapacity))
            omittedCount += max(0, candidates.count - visible.count)
            guard !visible.isEmpty else { continue }

            let items = visible.enumerated().map { offset, text in
                let clipped = clippedText(text)
                if clipped.wasShortened {
                    shortenedCount += 1
                }
                return VisitPreparationCardItem(
                    id: "\(sectionID.rawValue)-\(offset)",
                    text: clipped.value
                )
            }
            sections.append(
                VisitPreparationCardSection(
                    id: sectionID,
                    title: sectionID.title,
                    items: items
                )
            )
            remainingCapacity -= items.count
        }

        return VisitPreparationCardDocument(
            memberID: memberID,
            memberName: input.member.displayName,
            generatedAt: generatedAt,
            sections: sections,
            omittedItemCount: omittedCount,
            shortenedItemCount: shortenedCount,
            disclaimer: Copy.VisitPreparation.pdfDisclaimer
        )
    }

    private static func candidateItems(
        for sectionID: VisitPreparationSectionID,
        input: BriefInput,
        records: [BriefRecordSnapshot],
        medications: [BriefMedicationSnapshot],
        selectedRecordIDs: Set<UUID>,
        contact: String?,
        generatedAt: Date,
        calendar: Calendar
    ) -> [String] {
        switch sectionID {
        case .basicInfo:
            var values = [
                String(
                    format: Copy.VisitPreparation.name,
                    input.member.displayName
                )
            ]
            if let birthDate = input.member.birthDate,
               birthDate <= generatedAt,
               let age = calendar.dateComponents(
                   [.year],
                   from: birthDate,
                   to: generatedAt
               ).year,
               age >= 0 {
                values.append(
                    String(format: Copy.VisitPreparation.age, age)
                )
            }
            if let gender = trimmed(input.member.gender) {
                values.append(
                    String(format: Copy.VisitPreparation.gender, gender)
                )
            }
            return values
        case .allergies:
            return uniqueNonEmpty(input.member.allergies).map {
                String(format: Copy.VisitPreparation.allergy, $0)
            }
        case .currentMedications:
            return medications.map(medicationText)
        case .conditions:
            return uniqueNonEmpty(
                input.member.conditions
                    + records.compactMap(\.primaryDisease)
            ).map {
                String(format: Copy.VisitPreparation.condition, $0)
            }
        case .careTeam:
            return uniqueNonEmpty(
                records.compactMap(careTeamText)
            )
        case .keyRecords:
            return records
                .filter { selectedRecordIDs.contains($0.id) }
                .map(keyRecordText)
        case .questions:
            return uniqueNonEmpty(input.questions).map {
                String(format: Copy.VisitPreparation.question, $0)
            }
        case .contact:
            guard let contact = trimmed(contact) else { return [] }
            return [
                String(format: Copy.VisitPreparation.contact, contact)
            ]
        }
    }

    private static func careTeamText(
        _ record: BriefRecordSnapshot
    ) -> String? {
        let doctor = trimmed(record.doctor)
        let hospital = trimmed(record.hospital)
        switch (doctor, hospital) {
        case let (.some(doctor), .some(hospital)):
            return String(
                format: Copy.VisitPreparation.careTeam,
                doctor,
                hospital
            )
        case let (.some(doctor), .none):
            return String(
                format: Copy.VisitPreparation.doctorOnly,
                doctor
            )
        case let (.none, .some(hospital)):
            return String(
                format: Copy.VisitPreparation.hospitalOnly,
                hospital
            )
        case (.none, .none):
            return nil
        }
    }

    private static func keyRecordText(
        _ record: BriefRecordSnapshot
    ) -> String {
        let title = trimmed(record.title) ?? record.type.displayName
        let summary = trimmed(record.summary).map {
            String(format: Copy.VisitPreparation.summarySuffix, $0)
        } ?? ""
        return String(
            format: Copy.VisitPreparation.keyRecord,
            BriefFormatting.day.string(from: record.eventDate),
            title,
            summary
        )
    }

    private static func medicationText(
        _ medication: BriefMedicationSnapshot
    ) -> String {
        let dose: String
        if let value = medication.doseValue {
            dose = "\(numberText(value))\(medication.doseUnit)"
        } else {
            dose = medication.doseUnit
        }
        let frequency: String
        switch medication.frequency {
        case .dailyOne:
            frequency = Copy.VisitPreparation.frequencyDailyOne
        case .dailyTwo:
            frequency = Copy.VisitPreparation.frequencyDailyTwo
        case .dailyThree:
            frequency = Copy.VisitPreparation.frequencyDailyThree
        case .everyOtherDay:
            frequency = Copy.VisitPreparation.frequencyEveryOtherDay
        case .weekly:
            frequency = String(
                format: Copy.VisitPreparation.frequencyWeekly,
                medication.weeklyCount ?? 1
            )
        case .asNeeded:
            frequency = Copy.VisitPreparation.frequencyAsNeeded
        }
        return String(
            format: Copy.VisitPreparation.medication,
            medication.name,
            dose,
            frequency
        )
    }

    private static func clippedText(
        _ text: String
    ) -> (value: String, wasShortened: Bool) {
        let limit = VisitPreparationCardPolicy.maximumItemCharacters
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit - 1)) + "…", true)
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value = trimmed(value) else { return nil }
            let key = MemberIdentity.normalize(value)
            return seen.insert(key).inserted ? value : nil
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func recordOrder(
        _ lhs: BriefRecordSnapshot,
        _ rhs: BriefRecordSnapshot
    ) -> Bool {
        if lhs.eventDate != rhs.eventDate {
            return lhs.eventDate > rhs.eventDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func numberText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}
