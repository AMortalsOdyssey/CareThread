import Foundation
import SwiftData

struct ElderMedicationCardSnapshot: Equatable, Identifiable {
    let id: UUID
    let name: String
    let dose: String
    let time: String
    let usage: String
    let isPast: Bool
}
struct ElderFollowUpCardSnapshot: Equatable {
    let id: UUID
    let date: Date
    let dayText: String
    let countdownText: String
    let itemText: String
    let isOverdue: Bool
}

struct ElderTodaySnapshot: Equatable {
    let patientID: UUID
    let medications: [ElderMedicationCardSnapshot]
    let nextFollowUp: ElderFollowUpCardSnapshot?
    let pendingReviewCount: Int
}

enum ElderTodaySnapshotBuilder {
    static func build(
        patientID: UUID,
        medications: [Medication],
        followUps: [FollowUp],
        records: [MedicalRecord],
        now: Date,
        calendar: Calendar = CTDate.calendar
    ) -> ElderTodaySnapshot {
        let dayStart = calendar.startOfDay(for: now)
        let medicationCards = medications
            .filter {
                $0.patientId == patientID
                    && $0.lifecycleStatus == .active
                    && $0.isEffective(at: now)
            }
            .flatMap { medication in
                let times = medication.reminderTimes.isEmpty
                    ? [ReminderTime(hour: 8, minute: 0)]
                    : medication.reminderTimes
                return times.map { time in
                    ElderMedicationCardSnapshot(
                        id: stableCardID(
                            medicationID: medication.id,
                            hour: time.hour,
                            minute: time.minute
                        ),
                        name: medication.name,
                        dose: doseText(medication),
                        time: String(format: "%02d:%02d", time.hour, time.minute),
                        usage: MedicationUsageText.humanReadable(
                            medication.usageNotes
                        ),
                        isPast: isPast(time: time, now: now, calendar: calendar)
                    )
                }
            }
            .sorted {
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.id.uuidString < $1.id.uuidString
            }
        let next = followUps
            .filter {
                $0.patientId == patientID && $0.status == .pending
            }
            .sorted {
                if $0.plannedDate != $1.plannedDate {
                    return $0.plannedDate < $1.plannedDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
            .map { followUp in
                let plannedDay = calendar.startOfDay(for: followUp.plannedDate)
                let days = calendar.dateComponents(
                    [.day],
                    from: dayStart,
                    to: plannedDay
                ).day ?? 0
                let countdown: String
                if days < 0 {
                    countdown = "已过期 \(abs(days)) 天"
                } else if days == 0 {
                    countdown = "就是今天"
                } else {
                    countdown = "还有 \(days) 天"
                }
                return ElderFollowUpCardSnapshot(
                    id: followUp.id,
                    date: followUp.plannedDate,
                    dayText: monthDay.string(from: followUp.plannedDate),
                    countdownText: countdown,
                    itemText: followUp.items.joined(separator: "、"),
                    isOverdue: days < 0
                )
            }
        let pending = records.filter {
            $0.patientId == patientID && $0.reviewStatus == .pending
        }.count
        return ElderTodaySnapshot(
            patientID: patientID,
            medications: medicationCards,
            nextFollowUp: next,
            pendingReviewCount: pending
        )
    }

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = CTDate.calendar
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static func doseText(_ medication: Medication) -> String {
        let number = medication.doseValue.map {
            $0.formatted(.number.precision(.fractionLength(0...4)))
        } ?? ""
        return "\(number)\(medication.doseUnit)"
    }

    private static func isPast(
        time: ReminderTime,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return (components.hour ?? 0, components.minute ?? 0)
            >= (time.hour, time.minute)
    }

    private static func stableCardID(
        medicationID: UUID,
        hour: Int,
        minute: Int
    ) -> UUID {
        var bytes = medicationID.uuid
        bytes.14 ^= UInt8(clamping: hour)
        bytes.15 ^= UInt8(clamping: minute)
        return UUID(uuid: bytes)
    }
}

@MainActor
struct ElderTodayDataLoader {
    let context: ModelContext

    func load(
        patientID: UUID,
        now: Date = Date()
    ) throws -> ElderTodaySnapshot {
        let medicationDescriptor = FetchDescriptor<Medication>(
            predicate: #Predicate { $0.patientId == patientID }
        )
        let followUpDescriptor = FetchDescriptor<FollowUp>(
            predicate: #Predicate { $0.patientId == patientID }
        )
        let recordDescriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID }
        )
        return ElderTodaySnapshotBuilder.build(
            patientID: patientID,
            medications: try context.fetch(medicationDescriptor),
            followUps: try context.fetch(followUpDescriptor),
            records: try context.fetch(recordDescriptor),
            now: now
        )
    }
}
