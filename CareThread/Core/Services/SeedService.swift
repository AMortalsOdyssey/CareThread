import Foundation
import SwiftData

enum SeedService {
    static let patientID = UUID(uuidString: "28C19EF0-37C8-4B1F-B2DF-9CCFD2ED0DD4")!

    @MainActor
    static func seedDemo(into context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<Patient>())
        guard existing.isEmpty else {
            AppLog.data.info("Skipped demo seed because a patient already exists")
            return
        }

        let patient = Patient(
            id: patientID,
            name: "王晓芸",
            birthday: CTDate.make(1992, 6, 18),
            gender: "女",
            conditions: ["甲状腺癌术后随访"],
            allergies: ["青霉素"],
            histories: [HistoryItem(year: 2024, text: "甲状腺全切除术")],
            createdAt: CTDate.make(2024, 8, 22)
        )
        context.insert(patient)

        let records = demoRecords(patientId: patient.id)
        records.forEach(context.insert)

        let medicationOld = Medication(
            patientId: patient.id,
            name: "优甲乐",
            doseValue: 100,
            doseUnit: "µg",
            frequency: .dailyOne,
            usageNotes: ["晨起", "空腹", "口服"],
            startDate: CTDate.make(2024, 9, 2),
            endDate: CTDate.make(2026, 3, 15),
            isLongTerm: false
        )
        let medicationCurrent = Medication(
            patientId: patient.id,
            name: "优甲乐",
            doseValue: 75,
            doseUnit: "µg",
            frequency: .dailyOne,
            usageNotes: ["晨起", "空腹", "口服"],
            startDate: CTDate.make(2026, 3, 15),
            isLongTerm: true,
            previousVersionId: medicationOld.id,
            reminderEnabled: true,
            reminderTimes: [ReminderTime(hour: 8, minute: 0)]
        )
        context.insert(medicationOld)
        context.insert(medicationCurrent)

        let orderOne = MedicalOrder(
            patientId: patient.id,
            content: "术后 1 个月复查甲状腺功能",
            sourceRecordId: records[1].id,
            isCompleted: true,
            createdAt: CTDate.make(2024, 9, 2)
        )
        let orderTwo = MedicalOrder(
            patientId: patient.id,
            content: "3 个月后复查甲状腺功能",
            sourceRecordId: records[5].id,
            createdAt: CTDate.make(2026, 3, 15)
        )
        context.insert(orderOne)
        context.insert(orderTwo)

        let completed = FollowUp(
            patientId: patient.id,
            plannedDate: CTDate.make(2024, 10, 2),
            items: ["甲状腺功能"],
            reason: "术后复查",
            status: .completed,
            completedAt: CTDate.make(2024, 10, 2)
        )
        let upcoming = FollowUp(
            patientId: patient.id,
            plannedDate: CTDate.make(2026, 8, 15),
            items: ["甲状腺功能", "颈部超声"],
            reason: "用药调整后复查",
            bringRecordIds: [records[2].id, records[3].id]
        )
        context.insert(completed)
        context.insert(upcoming)
        try context.save()
        AppLog.data.info("Inserted deterministic demo seed")
    }

    @MainActor
    static func seedStress(_ count: Int, into context: ModelContext) throws {
        let patientId = patientID
        let insertedCount = max(0, count)
        for index in 0..<insertedCount {
            let dayOffset = -(index % 1_800)
            let date = CTDate.calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: CTDate.make(2026, 7, 30)
            ) ?? CTDate.make(2026, 7, 30)
            let type = RecordType.allCases[index % RecordType.allCases.count]
            context.insert(
                MedicalRecord(
                    patientId: patientId,
                    type: type,
                    title: "压测记录 \(index + 1)",
                    summary: "用于本地滚动性能验证的虚构记录。",
                    eventDate: date,
                    sourceType: .manual,
                    reviewStatus: .confirmed,
                    isKeyRecord: index.isMultiple(of: 17)
                )
            )
        }
        try context.save()
        AppLog.data.info("Inserted \(insertedCount) deterministic stress records")
    }

    static func demoRecords(patientId: UUID) -> [MedicalRecord] {
        [
            MedicalRecord(
                patientId: patientId,
                type: .pathology,
                title: "甲状腺病理报告",
                summary: "（右叶）甲状腺乳头状癌。",
                eventDate: CTDate.make(2024, 8, 22),
                hospital: "四川大学华西医院",
                department: "甲状腺外科",
                sourceType: .fixture,
                abnormalFlags: ["甲状腺乳头状癌"],
                reviewStatus: .confirmed,
                isKeyRecord: true,
                inBrief: true
            ),
            MedicalRecord(
                patientId: patientId,
                type: .discharge,
                title: "出院小结",
                summary: "甲状腺全切术后恢复良好。",
                eventDate: CTDate.make(2024, 9, 2),
                hospital: "四川大学华西医院",
                department: "甲状腺外科",
                sourceType: .fixture,
                reviewStatus: .confirmed
            ),
            MedicalRecord(
                patientId: patientId,
                type: .imaging,
                title: "胸部 CT 平扫",
                summary: "未见明显异常。",
                eventDate: CTDate.make(2025, 11, 3),
                hospital: "成都市第三人民医院",
                department: "放射科",
                sourceType: .fixture,
                reviewStatus: .confirmed
            ),
            MedicalRecord(
                patientId: patientId,
                type: .lab,
                title: "甲状腺功能五项",
                summary: "5 项指标，2 项异常：TSH 低，FT4 高。",
                eventDate: CTDate.make(2026, 3, 15),
                hospital: "四川大学华西医院",
                department: "内分泌科",
                sourceType: .fixture,
                labItems: [
                    LabItem(name: "TSH", value: 0.08, unit: "mIU/L", refLow: 0.27, refHigh: 4.2, flag: .low),
                    LabItem(name: "FT4", value: 22.8, unit: "pmol/L", refLow: 12, refHigh: 22, flag: .high)
                ],
                abnormalFlags: ["TSH 0.08 ↓", "FT4 22.8 ↑"],
                reviewStatus: .confirmed,
                inBrief: true
            ),
            MedicalRecord(
                patientId: patientId,
                type: .imaging,
                title: "颈部超声",
                summary: "术区及双侧颈部未见明确复发征象。",
                eventDate: CTDate.make(2026, 3, 15),
                hospital: "四川大学华西医院",
                department: "内分泌科",
                sourceType: .fixture,
                reviewStatus: .confirmed
            ),
            MedicalRecord(
                patientId: patientId,
                type: .outpatient,
                title: "门诊病历",
                summary: "左甲状腺素钠片调整为 75µg 每日 1 次。",
                eventDate: CTDate.make(2026, 3, 15),
                hospital: "四川大学华西医院",
                department: "甲状腺外科",
                sourceType: .fixture,
                reviewStatus: .pending
            )
        ]
    }
}
