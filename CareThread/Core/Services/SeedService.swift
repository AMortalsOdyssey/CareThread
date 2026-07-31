import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum SeedService {
    static let patientID = UUID(uuidString: "28C19EF0-37C8-4B1F-B2DF-9CCFD2ED0DD4")!

    @MainActor
    static func seedDemo(
        into context: ModelContext,
        vault: CaptureVaultService
    ) throws {
        let existing = try context.fetch(FetchDescriptor<Patient>())
        guard existing.isEmpty else {
            AppLog.data.info("Skipped demo seed because a patient already exists")
            return
        }

        let patient = Patient(
            id: patientID,
            name: "王晓芸",
            reportName: "王晓芸",
            birthday: CTDate.make(1992, 6, 18),
            gender: "女",
            conditions: ["甲状腺癌术后随访"],
            allergies: ["青霉素"],
            histories: [HistoryItem(year: 2024, text: "甲状腺全切除术")],
            createdAt: CTDate.make(2024, 8, 22)
        )
        context.insert(patient)

        let records = demoRecords(patientId: patient.id)
        let finalizations = try attachDemoOriginals(
            to: records,
            patientID: patient.id,
            vault: vault
        )
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
        do {
            try context.save()
        } catch {
            finalizations.reversed().forEach(vault.rollbackFinalization)
            throw error
        }
        try vault.markDatabaseCommitted(finalizations)
        for batchID in Set(finalizations.map(\.staged.batchID)) {
            try vault.completeBatchIfPossible(batchID)
        }
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
                doctor: "李医生",
                primaryDisease: "甲状腺乳头状癌",
                ageAtEvent: 32,
                sourceType: .fixture,
                ocrText: "病理诊断：（右叶）甲状腺乳头状癌。建议结合临床随访。",
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
                doctor: "李医生",
                primaryDisease: "甲状腺乳头状癌术后",
                ageAtEvent: 32,
                sourceType: .fixture,
                ocrText: "出院情况：切口愈合良好，一般情况稳定。出院后按时服药并复查。",
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
                doctor: "陈医生",
                ageAtEvent: 33,
                sourceType: .fixture,
                ocrText: "检查所见：双肺纹理清晰，未见明显结节及渗出。检查结论：胸部 CT 未见明显异常。",
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
                doctor: "周医生",
                primaryDisease: "甲状腺癌术后随访",
                ageAtEvent: 33,
                sourceType: .fixture,
                ocrText: "TSH 0.08 mIU/L↓；FT4 22.8 pmol/L↑；FT3 4.6 pmol/L；Tg 0.12 ng/mL；TgAb 18 IU/mL。",
                labItems: [
                    LabItem(name: "TSH", value: 0.08, unit: "mIU/L", refLow: 0.27, refHigh: 4.2, flag: .low),
                    LabItem(name: "FT4", value: 22.8, unit: "pmol/L", refLow: 12, refHigh: 22, flag: .high),
                    LabItem(name: "FT3", value: 4.6, unit: "pmol/L", refLow: 3.1, refHigh: 6.8, flag: .none),
                    LabItem(name: "Tg", value: 0.12, unit: "ng/mL", refLow: 0, refHigh: 55, flag: .none),
                    LabItem(name: "TgAb", value: 18, unit: "IU/mL", refLow: 0, refHigh: 115, flag: .none)
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
                department: "超声医学科",
                doctor: "杨医生",
                primaryDisease: "甲状腺癌术后随访",
                ageAtEvent: 33,
                sourceType: .fixture,
                ocrText: "超声所见：甲状腺术后，术区未见明确异常回声，双侧颈部未见明显肿大淋巴结。",
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
                doctor: "李医生",
                primaryDisease: "甲状腺癌术后随访",
                ageAtEvent: 33,
                sourceType: .fixture,
                ocrText: "结合本次甲功结果，将左甲状腺素钠片调整为 75µg，每日一次，三个月后复查甲功及颈部超声。",
                reviewStatus: .pending
            )
        ]
    }

    @MainActor
    private static func attachDemoOriginals(
        to records: [MedicalRecord],
        patientID: UUID,
        vault: CaptureVaultService
    ) throws -> [FinalizedCaptureAsset] {
        var finalizations: [FinalizedCaptureAsset] = []
        do {
            for record in records {
                let batchID = UUID()
                let data = try renderedOriginalData(for: record)
                let staged = try vault.stagePhotoData(
                    data,
                    batchID: batchID,
                    displayName: "\(record.displayTitle)-虚构演示原件.jpg",
                    preferredExtension: "jpg",
                    uniformTypeIdentifier: UTType.jpeg.identifier
                )
                let finalized = try vault.finalize(
                    asset: staged,
                    patientID: patientID,
                    recordID: record.id
                )
                finalizations.append(finalized)
                let attachment = try Attachment.verified(
                    id: staged.id,
                    patientId: patientID,
                    recordId: record.id,
                    originalRelativePath: finalized.finalRelativePath,
                    derivedRelativePath: finalized.finalPreviewRelativePath,
                    displayFileName: staged.displayName,
                    kind: .image,
                    pageIndex: 0,
                    uniformTypeIdentifier: staged.uniformTypeIdentifier,
                    byteCount: staged.byteCount,
                    sha256: staged.sha256,
                    importedAt: staged.createdAt,
                    importSource: .fixture,
                    pixelWidth: staged.pixelWidth,
                    pixelHeight: staged.pixelHeight,
                    pageCount: 1
                )
                try record.bindAttachment(attachment)
            }
            return finalizations
        } catch {
            finalizations.reversed().forEach(vault.rollbackFinalization)
            throw error
        }
    }

    @MainActor
    private static func renderedOriginalData(for record: MedicalRecord) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 900, height: 1_200)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor(CT.Color.bgElevated).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let titleStyle: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .bold),
                .foregroundColor: UIColor(CT.Color.inkPrimary)
            ]
            let headingStyle: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: UIColor(CT.Color.inkPrimary)
            ]
            let bodyStyle: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22),
                .foregroundColor: UIColor(CT.Color.inkSecondary)
            ]

            ("虚构演示资料 · 非真实病历" as NSString).draw(
                at: CGPoint(x: 64, y: 64),
                withAttributes: bodyStyle
            )
            (record.displayTitle as NSString).draw(
                in: CGRect(x: 64, y: 120, width: 772, height: 100),
                withAttributes: titleStyle
            )
            let organization = [
                record.hospital,
                record.department,
                record.doctor
            ].compactMap { $0 }.joined(separator: " · ")
            (organization as NSString).draw(
                in: CGRect(x: 64, y: 230, width: 772, height: 70),
                withAttributes: bodyStyle
            )
            let dateText = record.eventDate.formatted(
                .dateTime
                    .locale(Locale(identifier: "zh_CN"))
                    .year()
                    .month()
                    .day()
            )
            ("姓名：王晓芸    日期：\(dateText)" as NSString).draw(
                in: CGRect(x: 64, y: 315, width: 772, height: 70),
                withAttributes: bodyStyle
            )
            ("结论" as NSString).draw(
                at: CGPoint(x: 64, y: 430),
                withAttributes: headingStyle
            )
            (record.summary as NSString).draw(
                in: CGRect(x: 64, y: 485, width: 772, height: 150),
                withAttributes: bodyStyle
            )
            ("报告内容" as NSString).draw(
                at: CGPoint(x: 64, y: 680),
                withAttributes: headingStyle
            )
            ((record.ocrText ?? record.summary) as NSString).draw(
                in: CGRect(x: 64, y: 735, width: 772, height: 320),
                withAttributes: bodyStyle
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw SeedServiceError.cannotRenderOriginal
        }
        return data
    }
}

private enum SeedServiceError: Error {
    case cannotRenderOriginal
}
