import Foundation

enum BriefBuilder {
    static func build(
        input: BriefInput,
        selection: BriefSelection = BriefSelection(),
        generatedAt: Date,
        calendar: Calendar = CTDate.calendar
    ) -> BriefDocument {
        let patientID = input.member.id
        let confirmedRecords = input.records.filter {
            $0.patientID == patientID && $0.reviewStatus == .confirmed
        }
        let scopedMedications = input.medications.filter {
            $0.patientID == patientID && $0.isCurrent(at: generatedAt)
        }
        let scopedFollowUps = input.followUps.filter {
            $0.patientID == patientID && $0.status == .pending
        }
        let selectedIDs = selection.selectedRecordIDs
            ?? Set(confirmedRecords.filter(\.isInBrief).map(\.id))
        let selectedRecords = confirmedRecords.filter {
            selectedIDs.contains($0.id)
        }
        let sixMonthRecords = confirmedRecords.filter {
            DateRangePreset.sixMonths.contains(
                $0.eventDate,
                endingAt: generatedAt,
                calendar: calendar
            )
        }
        let recentAbnormalRecords = sixMonthRecords.filter(\.isAbnormal)
        var referencedRecords: [BriefRecordSnapshot] = []
        if selection.enabledSections.contains(.recentKeyResults) {
            referencedRecords += recentAbnormalRecords
        }
        if selection.enabledSections.contains(.selectedRecords) {
            referencedRecords += selectedRecords
        }
        let sourceRecords = uniqueRecords(referencedRecords)
            .sorted(by: recordOrder)
        let sourceNumbers = Dictionary(
            uniqueKeysWithValues: sourceRecords.enumerated().map {
                ($0.element.id, $0.offset + 1)
            }
        )

        let sections: [BriefSection] = BriefSectionID.allCases.compactMap {
            sectionID -> BriefSection? in
            guard selection.enabledSections.contains(sectionID) else {
                return nil
            }
            let items = items(
                for: sectionID,
                input: input,
                confirmedRecords: confirmedRecords,
                recentAbnormalRecords: recentAbnormalRecords,
                selectedRecords: selectedRecords,
                medications: scopedMedications,
                followUps: scopedFollowUps,
                sourceNumbers: sourceNumbers,
                generatedAt: generatedAt,
                calendar: calendar
            )
            guard !items.isEmpty else { return nil }
            return BriefSection(
                id: sectionID,
                title: sectionID.title,
                items: items
            )
        }
        let sources = sourceRecords.enumerated().map {
            BriefSource(
                number: $0.offset + 1,
                recordID: $0.element.id,
                eventDate: $0.element.eventDate,
                title: displayTitle($0.element),
                recordType: $0.element.type
            )
        }
        return BriefDocument(
            memberID: patientID,
            memberName: input.member.displayName,
            generatedAt: generatedAt,
            sections: sections,
            sources: sources,
            disclaimer: "本摘要仅在设备本地整理已有资料，不提供诊断、治疗或用药建议。请以医生意见为准。"
        )
    }

    static func exportPayload(
        input: BriefInput,
        preset: DateRangePreset,
        selection: BriefSelection = BriefSelection(),
        generatedAt: Date,
        calendar: Calendar = CTDate.calendar
    ) -> RecordExportPayload {
        let brief = build(
            input: input,
            selection: selection,
            generatedAt: generatedAt,
            calendar: calendar
        )
        let records = input.records
            .filter {
                $0.patientID == input.member.id
                    && $0.reviewStatus == .confirmed
                    && preset.contains(
                        $0.eventDate,
                        endingAt: generatedAt,
                        calendar: calendar
                    )
            }
            .sorted(by: recordOrder)
        return RecordExportPayload(
            memberID: input.member.id,
            memberName: input.member.displayName,
            generatedAt: generatedAt,
            rangeName: preset.displayName,
            brief: brief,
            records: records
        )
    }

    private static func items(
        for sectionID: BriefSectionID,
        input: BriefInput,
        confirmedRecords: [BriefRecordSnapshot],
        recentAbnormalRecords: [BriefRecordSnapshot],
        selectedRecords: [BriefRecordSnapshot],
        medications: [BriefMedicationSnapshot],
        followUps: [BriefFollowUpSnapshot],
        sourceNumbers: [UUID: Int],
        generatedAt: Date,
        calendar: Calendar
    ) -> [BriefItem] {
        switch sectionID {
        case .basicProfile:
            return basicProfileItems(
                input.member,
                generatedAt: generatedAt,
                calendar: calendar
            )
        case .currentIssues:
            let symptoms = confirmedRecords
                .flatMap(\.tags)
                .filter { $0.kind == .symptom }
                .map(\.value)
            return uniqueNonEmpty(symptoms).enumerated().map {
                BriefItem(
                    id: "issue-\($0.offset)-\($0.element)",
                    text: $0.element,
                    sourceNumber: nil,
                    sourceRecordID: nil
                )
            }
        case .recentKeyResults:
            return recentAbnormalRecords
                .sorted(by: recordOrder)
                .map { recordItem($0, prefix: dateText($0.eventDate), sourceNumbers: sourceNumbers) }
        case .currentMedications:
            return medications.sorted {
                if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                return $0.id.uuidString < $1.id.uuidString
            }.map {
                BriefItem(
                    id: "medication-\($0.id.uuidString)",
                    text: medicationText($0),
                    sourceNumber: nil,
                    sourceRecordID: nil
                )
            }
        case .allergiesAndHistory:
            let allergies = uniqueNonEmpty(input.member.allergies).map {
                "过敏：\($0)"
            }
            let histories = input.member.histories
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted {
                    if $0.year != $1.year { return $0.year > $1.year }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .map { "\($0.year)：\($0.text)" }
            return (allergies + histories).enumerated().map {
                BriefItem(
                    id: "history-\($0.offset)-\($0.element)",
                    text: $0.element,
                    sourceNumber: nil,
                    sourceRecordID: nil
                )
            }
        case .pendingFollowUps:
            return followUps.sorted {
                if $0.plannedDate != $1.plannedDate { return $0.plannedDate < $1.plannedDate }
                return $0.id.uuidString < $1.id.uuidString
            }.map {
                let reason = trimmed($0.reason).map { "；原因：\($0)" } ?? ""
                return BriefItem(
                    id: "followup-\($0.id.uuidString)",
                    text: "\(dateText($0.plannedDate)) \($0.items.joined(separator: "、"))\(reason)",
                    sourceNumber: nil,
                    sourceRecordID: nil
                )
            }
        case .selectedRecords:
            return selectedRecords
                .sorted(by: recordOrder)
                .map { recordItem($0, prefix: dateText($0.eventDate), sourceNumbers: sourceNumbers) }
        case .questions:
            return uniqueNonEmpty(input.questions).enumerated().map {
                BriefItem(
                    id: "question-\($0.offset)-\($0.element)",
                    text: $0.element,
                    sourceNumber: nil,
                    sourceRecordID: nil
                )
            }
        }
    }

    private static func basicProfileItems(
        _ member: BriefMemberSnapshot,
        generatedAt: Date,
        calendar: Calendar
    ) -> [BriefItem] {
        var parts = ["姓名：\(member.displayName)"]
        if let birthDate = member.birthDate,
           birthDate <= generatedAt {
            let age = calendar.dateComponents(
                [.year],
                from: birthDate,
                to: generatedAt
            ).year
            if let age, age >= 0 {
                parts.append("年龄：\(age) 岁")
            }
        }
        let conditions = uniqueNonEmpty(member.conditions)
        if !conditions.isEmpty {
            parts.append("主要病种：\(conditions.joined(separator: "、"))")
        }
        return parts.enumerated().map {
            BriefItem(
                id: "profile-\($0.offset)",
                text: $0.element,
                sourceNumber: nil,
                sourceRecordID: nil
            )
        }
    }

    private static func recordItem(
        _ record: BriefRecordSnapshot,
        prefix: String,
        sourceNumbers: [UUID: Int]
    ) -> BriefItem {
        let title = displayTitle(record)
        let summary = trimmed(record.summary)
        let detail = summary.map { "：\($0)" } ?? ""
        return BriefItem(
            id: "record-\(record.id.uuidString)",
            text: "\(prefix) \(title)\(detail)",
            sourceNumber: sourceNumbers[record.id],
            sourceRecordID: record.id
        )
    }

    private static func medicationText(_ medication: BriefMedicationSnapshot) -> String {
        let dose: String
        if let value = medication.doseValue {
            dose = "\(numberText(value))\(medication.doseUnit)"
        } else {
            dose = medication.doseUnit
        }
        let frequency: String
        switch medication.frequency {
        case .dailyOne: frequency = "每日 1 次"
        case .dailyTwo: frequency = "每日 2 次"
        case .dailyThree: frequency = "每日 3 次"
        case .everyOtherDay: frequency = "隔日"
        case .weekly: frequency = "每周 \(medication.weeklyCount ?? 1) 次"
        case .asNeeded: frequency = "按需"
        }
        return "\(medication.name) \(dose) · \(frequency) · \(dateText(medication.startDate)) 起"
    }

    private static func uniqueRecords(
        _ records: [BriefRecordSnapshot]
    ) -> [BriefRecordSnapshot] {
        var seen = Set<UUID>()
        return records.filter { seen.insert($0.id).inserted }
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
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            return nil
        }
        return result
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

    private static func displayTitle(_ record: BriefRecordSnapshot) -> String {
        trimmed(record.title) ?? record.type.displayName
    }

    private static func dateText(_ date: Date) -> String {
        BriefFormatting.day.string(from: date)
    }

    private static func numberText(_ number: Double) -> String {
        number.formatted(
            .number.precision(.fractionLength(0...3))
        )
    }
}

enum BriefFormatting {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
