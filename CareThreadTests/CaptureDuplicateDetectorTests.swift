import Foundation
import SwiftData
import Testing
import UIKit
@testable import CareThread

private typealias Attachment = CareThread.Attachment

/// All report contents, names and identifiers in this suite are fictional.
struct CaptureDuplicateDetectorTests {
    @Test("同一批次原图 SHA 相同属于不可覆盖的精确重复")
    func exactHashInCurrentImportIsHardBlocked() throws {
        let first = candidate(
            name: "虚构报告-1.png",
            sha256: String(repeating: "a", count: 64)
        )
        let second = candidate(
            name: "虚构报告-2.png",
            sha256: String(repeating: "a", count: 64)
        )

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [first, second],
                records: []
            )
        )

        #expect(match.evidence == .exactFileHash)
        #expect(match.scope == .currentImport)
        #expect(match.isHardBlock)
    }

    @Test("与同成员历史附件 SHA 相同优先于 OCR 内容判定")
    func savedExactHashTakesPriority() throws {
        let hash = String(repeating: "b", count: 64)
        let candidate = candidate(
            name: "重复化验单.png",
            sha256: hash,
            ocrText: fictionalOCR
        )
        let record = CaptureDuplicateRecordSnapshot(
            id: UUID(),
            title: "虚构甲状腺化验",
            eventDate: CTDate.make(2026, 3, 12),
            ocrText: fictionalOCR,
            attachments: [
                CaptureDuplicateAttachmentSnapshot(
                    id: UUID(),
                    sha256: hash,
                    visualURL: nil,
                    pixelWidth: 1_200,
                    pixelHeight: 1_600
                )
            ]
        )

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [candidate],
                records: [record]
            )
        )

        #expect(match.evidence == .exactFileHash)
        #expect(match.scope == .savedRecord)
        #expect(match.existingRecordID == record.id)
    }

    @Test("同一虚构报告采用 PNG 与 JPEG 重编码后由视觉内容指纹识别")
    func reencodedImageUsesPerceptualHash() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = reportImage(
            title: "虚构市第一医院",
            lines: ["报告号 CT-0007", "TSH 0.08", "检验日期 2026-03-12"]
        )
        let pngURL = directory.appendingPathComponent("report.png")
        let jpegURL = directory.appendingPathComponent("report.jpg")
        try #require(image.pngData()).write(to: pngURL)
        try #require(image.jpegData(compressionQuality: 0.62)).write(to: jpegURL)

        let pngHash = try CaptureVaultService.sha256File(at: pngURL)
        let jpegHash = try CaptureVaultService.sha256File(at: jpegURL)
        #expect(pngHash != jpegHash)

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [
                    candidate(
                        name: "重新导出的报告.jpg",
                        sha256: jpegHash,
                        visualURL: jpegURL
                    )
                ],
                records: [
                    CaptureDuplicateRecordSnapshot(
                        id: UUID(),
                        title: "虚构检验报告",
                        eventDate: CTDate.make(2026, 3, 12),
                        ocrText: "",
                        attachments: [
                            CaptureDuplicateAttachmentSnapshot(
                                id: UUID(),
                                sha256: pngHash,
                                visualURL: pngURL,
                                pixelWidth: 1_200,
                                pixelHeight: 1_600
                            )
                        ]
                    )
                ]
            )
        )

        #expect(match.evidence == .visualContentHash)
        #expect(!match.isHardBlock)
        #expect(match.similarity >= 0.92)
    }

    @Test("同一虚构报告模拟重新拍照后仍由视觉内容指纹识别")
    func simulatedRetakeUsesPerceptualHash() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = reportImage(
            title: "虚构市第一医院",
            lines: ["报告号 CT-0007", "TSH 0.08", "检验日期 2026-03-12"]
        )
        let retake = simulatedRetake(of: original)
        let originalURL = directory.appendingPathComponent("original.png")
        let retakeURL = directory.appendingPathComponent("retake.jpg")
        try #require(original.pngData()).write(to: originalURL)
        try #require(retake.jpegData(compressionQuality: 0.72)).write(to: retakeURL)
        let originalFingerprint = try #require(
            CapturePerceptualImageHash.make(url: originalURL)
        )
        let retakeFingerprint = try #require(
            CapturePerceptualImageHash.make(url: retakeURL)
        )
        #expect(
            CapturePerceptualImageHash.similarity(
                originalFingerprint,
                retakeFingerprint
            ) != nil,
            """
            模拟重拍应由可跨平台的本地视觉指纹识别；DCT 距离 \
            \(String(describing: CapturePerceptualImageHash.minimumHammingDistance(
                originalFingerprint.dctHashes,
                retakeFingerprint.dctHashes
            )))，block 距离 \
            \(String(describing: CapturePerceptualImageHash.minimumHammingDistance(
                originalFingerprint.blockHashes,
                retakeFingerprint.blockHashes
            )))，dHash 距离 \
            \(String(describing: CapturePerceptualImageHash.minimumHammingDistance(
                originalFingerprint.differenceHashes,
                retakeFingerprint.differenceHashes
            )))
            """
        )

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [
                    candidate(
                        name: "重新拍摄.jpg",
                        sha256: try CaptureVaultService.sha256File(at: retakeURL),
                        visualURL: retakeURL
                    )
                ],
                records: [
                    CaptureDuplicateRecordSnapshot(
                        id: UUID(),
                        title: "虚构检验报告",
                        eventDate: CTDate.make(2026, 3, 12),
                        ocrText: "",
                        attachments: [
                            CaptureDuplicateAttachmentSnapshot(
                                id: UUID(),
                                sha256: try CaptureVaultService.sha256File(
                                    at: originalURL
                                ),
                                visualURL: originalURL,
                                pixelWidth: 1_200,
                                pixelHeight: 1_600
                            )
                        ]
                    )
                ]
            )
        )

        #expect(match.evidence == .visualContentHash)
    }

    @Test("长 OCR 有误且重拍裁边改变宽高比时仍执行视觉查重")
    func croppedRetakeWithNoisyLongOCRStillUsesVisualFallback() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = reportImage(
            title: "虚构市第一医院",
            lines: [
                "生化检验报告",
                "虚构指标甲 18.2",
                "虚构指标乙 6.4",
                "本页仅用于自动化测试"
            ]
        )
        let retake = verticallyCroppedRetake(of: original)
        let originalURL = directory.appendingPathComponent("original.png")
        let retakeURL = directory.appendingPathComponent("cropped-retake.jpg")
        try #require(original.pngData()).write(to: originalURL)
        try #require(retake.jpegData(compressionQuality: 0.70)).write(to: retakeURL)

        let noisyCandidateOCR = """
        虚构巿笫一医阮 生北捡验报吿 测试页靣重新拍摄后产生较多识别错字
        指标甲十八点二 指标乙六点四 仅用于自动化边界验证与离线查重测试
        """
        let historicalOCR = """
        虚构市第一医院 生化检验报告 这是一份内容较长的历史识别结果
        虚构指标甲 18.2 虚构指标乙 6.4 本页完全虚构且仅用于自动化测试
        """
        #expect(
            CaptureDuplicateTextFingerprint.normalized(noisyCandidateOCR).count
                >= CaptureDuplicateTextFingerprint.minimumNormalizedCharacters
        )
        #expect(
            CaptureDuplicateTextFingerprint.normalized(historicalOCR).count
                >= CaptureDuplicateTextFingerprint.minimumNormalizedCharacters
        )
        #expect(
            CaptureDuplicateTextFingerprint.similarity(
                noisyCandidateOCR,
                historicalOCR
            ) == nil
        )

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [
                    CaptureDuplicateCandidateSnapshot(
                        id: UUID(),
                        displayName: "重拍裁边报告.jpg",
                        sha256: try CaptureVaultService.sha256File(
                            at: retakeURL
                        ),
                        visualURL: retakeURL,
                        pixelWidth: 1_200,
                        pixelHeight: 1_300,
                        ocrText: noisyCandidateOCR
                    )
                ],
                records: [
                    CaptureDuplicateRecordSnapshot(
                        id: UUID(),
                        title: "虚构历史检验报告",
                        eventDate: CTDate.make(2026, 7, 31),
                        ocrText: historicalOCR,
                        attachments: [
                            CaptureDuplicateAttachmentSnapshot(
                                id: UUID(),
                                sha256: try CaptureVaultService.sha256File(
                                    at: originalURL
                                ),
                                visualURL: originalURL,
                                pixelWidth: 1_200,
                                pixelHeight: 1_600
                            )
                        ]
                    )
                ]
            )
        )

        #expect(match.evidence == .visualContentHash)
        #expect(match.scope == .savedRecord)
    }

    @Test("同一虚构报告旋转九十度后仍由视觉内容指纹识别")
    func quarterTurnUsesPerceptualHash() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = reportImage(
            title: "虚构市第一医院",
            lines: ["报告号 CT-ROT9", "虚构指标 42", "检验日期 2026-07-31"]
        )
        let rotated = rotatedQuarterTurn(of: original)
        let originalURL = directory.appendingPathComponent("original.png")
        let rotatedURL = directory.appendingPathComponent("rotated.png")
        try #require(original.pngData()).write(to: originalURL)
        try #require(rotated.pngData()).write(to: rotatedURL)

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [
                    candidate(
                        name: "旋转后的报告.png",
                        sha256: try CaptureVaultService.sha256File(
                            at: rotatedURL
                        ),
                        visualURL: rotatedURL
                    )
                ],
                records: [
                    CaptureDuplicateRecordSnapshot(
                        id: UUID(),
                        title: "虚构检验报告",
                        eventDate: CTDate.make(2026, 7, 31),
                        ocrText: "",
                        attachments: [
                            CaptureDuplicateAttachmentSnapshot(
                                id: UUID(),
                                sha256: try CaptureVaultService.sha256File(
                                    at: originalURL
                                ),
                                visualURL: originalURL,
                                pixelWidth: 1_200,
                                pixelHeight: 1_600
                            )
                        ]
                    )
                ]
            )
        )

        #expect(match.evidence == .visualContentHash)
    }

    @Test("图片哈希不同但 OCR 内容高度重叠时识别为疑似重复")
    func contentOverlapDetectsDifferentImages() throws {
        let candidate = candidate(
            name: "重新拍摄.jpg",
            sha256: String(repeating: "c", count: 64),
            ocrText: fictionalOCR + "\n拍摄角度略有变化"
        )
        let record = CaptureDuplicateRecordSnapshot(
            id: UUID(),
            title: "虚构甲状腺化验",
            eventDate: CTDate.make(2026, 3, 12),
            ocrText: fictionalOCR,
            attachments: []
        )

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [candidate],
                records: [record]
            )
        )

        #expect(match.evidence == .ocrContentOverlap)
        #expect(match.similarity >= 0.92)
        #expect(!match.isHardBlock)
    }

    @Test("短模板词和低重叠内容不会误报")
    func shortOrLowOverlapTextDoesNotMatch() {
        let short = candidate(
            name: "短文本.jpg",
            sha256: String(repeating: "d", count: 64),
            ocrText: "检验报告 正常范围"
        )
        let unrelated = CaptureDuplicateRecordSnapshot(
            id: UUID(),
            title: "虚构影像记录",
            eventDate: CTDate.make(2025, 8, 1),
            ocrText: """
            虚构市第二医院 胸部影像检查
            报告编号 XR-9912 检查日期 2025-08-01
            双肺纹理清晰，未见虚构异常描述。
            """,
            attachments: []
        )

        #expect(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [short],
                records: [unrelated]
            ) == nil
        )
    }

    @Test("同医院模板但报告日期与编号冲突时不产生 OCR 误报")
    func templateWithConflictingDiscriminatorsDoesNotMatch() {
        let oldText = """
        虚构市第一医院甲状腺功能检验报告
        报告编号 CT-0007 检验日期 2026-03-12
        TSH 0.08 mIU/L 参考范围 0.27-4.20
        FT4 24.6 pmol/L 参考范围 12.0-22.0
        本内容完全虚构，仅供自动化测试。
        """
        let newText = """
        虚构市第一医院甲状腺功能检验报告
        报告编号 CT-9918 检验日期 2026-07-29
        TSH 0.08 mIU/L 参考范围 0.27-4.20
        FT4 24.6 pmol/L 参考范围 12.0-22.0
        本内容完全虚构，仅供自动化测试。
        """

        #expect(
            CaptureDuplicateTextFingerprint.similarity(oldText, newText) == nil
        )
    }

    @Test("当前单页包含于历史多页 OCR 时仍识别重复")
    func onePageContainedInHistoricalMultiPageTextMatches() throws {
        let historical = fictionalOCR + (1...4).map {
            "\n虚构报告后续第\($0)页：附加说明段落仅用于扩大历史多页文本。"
        }.joined()
        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [
                    candidate(
                        name: "重传其中一页.jpg",
                        sha256: String(repeating: "8", count: 64),
                        ocrText: fictionalOCR
                    )
                ],
                records: [
                    CaptureDuplicateRecordSnapshot(
                        id: UUID(),
                        title: "虚构五页报告",
                        eventDate: CTDate.make(2026, 3, 12),
                        ocrText: historical,
                        attachments: []
                    )
                ]
            )
        )

        #expect(match.evidence == .ocrContentOverlap)
        #expect(match.scope == .savedRecord)
    }

    @Test("真实长度的四页报告中任一独立页面重传仍识别重复")
    func distinctLongPageContainedInFourPageRecordMatches() throws {
        let pages = fictionalFourPageOCR
        #expect(Set(pages).count == 4)
        #expect(pages.map(\.count).max()! - pages.map(\.count).min()! < 80)

        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [
                    candidate(
                        name: "虚构住院记录-第三页.jpg",
                        sha256: String(repeating: "3", count: 64),
                        ocrText: pages[2]
                    )
                ],
                records: [
                    CaptureDuplicateRecordSnapshot(
                        id: UUID(),
                        title: "虚构四页住院记录",
                        eventDate: CTDate.make(2026, 4, 18),
                        ocrText: pages.joined(separator: "\n\n"),
                        attachments: []
                    )
                ]
            )
        )

        #expect(match.evidence == .ocrContentOverlap)
        #expect(match.scope == .savedRecord)
        #expect(match.similarity >= 0.97)
    }

    @Test("本次多页聚合文本与历史整份报告一致时识别重复")
    func aggregateCurrentPagesMatchHistoricalRecord() throws {
        let pageOne = String(fictionalOCR.prefix(fictionalOCR.count / 2))
        let pageTwo = String(fictionalOCR.suffix(fictionalOCR.count / 2))
        let match = try #require(
            CaptureDuplicateDetector.strongestMatch(
                candidates: [
                    candidate(
                        name: "第一页.jpg",
                        sha256: String(repeating: "6", count: 64),
                        ocrText: pageOne
                    ),
                    candidate(
                        name: "第二页.jpg",
                        sha256: String(repeating: "7", count: 64),
                        ocrText: pageTwo
                    )
                ],
                records: [
                    CaptureDuplicateRecordSnapshot(
                        id: UUID(),
                        title: "虚构两页报告",
                        eventDate: CTDate.make(2026, 3, 12),
                        ocrText: fictionalOCR,
                        attachments: []
                    )
                ]
            )
        )

        #expect(match.evidence == .ocrContentOverlap)
        #expect(match.scope == .savedRecord)
    }

    @Test("OCR 全角与半角差异归一化后视为同一内容")
    func fullWidthAndHalfWidthOCRAreEquivalent() throws {
        let halfWidth = """
        虚构市第三医院 生化检验报告
        报告编号 LAB-2468 检验日期 2026-04-18
        GLU 5.60 mmol/L ALT 23 U/L AST 21 U/L
        本内容完全虚构，仅用于宽度归一化自动化测试。
        """
        let fullWidth = """
        虚构市第三医院　生化检验报告
        报告编号　ＬＡＢ－２４６８　检验日期　２０２６－０４－１８
        ＧＬＵ　５．６０　ｍｍｏｌ／Ｌ　ＡＬＴ　２３　Ｕ／Ｌ　ＡＳＴ　２１　Ｕ／Ｌ
        本内容完全虚构，仅用于宽度归一化自动化测试。
        """

        let similarity = try #require(
            CaptureDuplicateTextFingerprint.similarity(halfWidth, fullWidth)
        )
        #expect(similarity == 1)
    }

    @Test("视觉内容明显不同的同尺寸图片不会误报")
    func unrelatedImagesDoNotProduceVisualMatch() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = directory.appendingPathComponent("report.png")
        let chartURL = directory.appendingPathComponent("chart.png")
        try #require(
            reportImage(
                title: "虚构市第一医院",
                lines: ["检验报告", "TSH 0.08", "日期 2026-03-12"]
            ).pngData()
        ).write(to: reportURL)
        try #require(unrelatedChartImage().pngData()).write(to: chartURL)
        let reportFingerprint = try #require(
            CapturePerceptualImageHash.make(url: reportURL)
        )
        let chartFingerprint = try #require(
            CapturePerceptualImageHash.make(url: chartURL)
        )

        let match = CaptureDuplicateDetector.strongestMatch(
            candidates: [
                candidate(
                    name: "虚构化验单.png",
                    sha256: try CaptureVaultService.sha256File(at: reportURL),
                    visualURL: reportURL
                )
            ],
            records: [
                CaptureDuplicateRecordSnapshot(
                    id: UUID(),
                    title: "虚构趋势图",
                    eventDate: CTDate.make(2026, 4, 18),
                    ocrText: "",
                    attachments: [
                        CaptureDuplicateAttachmentSnapshot(
                            id: UUID(),
                            sha256: try CaptureVaultService.sha256File(at: chartURL),
                            visualURL: chartURL,
                            pixelWidth: 1_200,
                            pixelHeight: 1_600
                        )
                    ]
                )
            ]
        )

        #expect(
            match == nil,
            """
            无关图片不应命中；block 距离 \
            \(String(describing: CapturePerceptualImageHash.minimumHammingDistance(
                reportFingerprint.blockHashes,
                chartFingerprint.blockHashes
            )))，dHash 距离 \
            \(String(describing: CapturePerceptualImageHash.minimumHammingDistance(
                reportFingerprint.differenceHashes,
                chartFingerprint.differenceHashes
            )))
            """
        )
    }

    @Test("同医院模板但报告号日期和指标均不同不会被视觉指纹误报")
    func sameTemplateWithDifferentValuesDoesNotProduceVisualMatch() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.png")
        let newURL = directory.appendingPathComponent("new.png")
        let oldText = """
        虚构市第一医院甲状腺功能检验报告
        报告编号 CT-0007 检验日期 2026-03-12
        TSH 0.08 FT4 24.6 FT3 8.1 TGAB 16.0
        本内容完全虚构，仅供自动化测试。
        """
        let newText = """
        虚构市第一医院甲状腺功能检验报告
        报告编号 CT-9918 检验日期 2026-07-29
        TSH 3.96 FT4 12.2 FT3 3.4 TGAB 89.5
        本内容完全虚构，仅供自动化测试。
        """
        try #require(
            reportImage(
                title: "虚构市第一医院",
                lines: [
                    "报告编号 CT-0007",
                    "检验日期 2026-03-12",
                    "TSH 0.08  FT4 24.6",
                    "FT3 8.1  TGAB 16.0"
                ]
            ).pngData()
        ).write(to: oldURL)
        try #require(
            reportImage(
                title: "虚构市第一医院",
                lines: [
                    "报告编号 CT-9918",
                    "检验日期 2026-07-29",
                    "TSH 3.96  FT4 12.2",
                    "FT3 3.4  TGAB 89.5"
                ]
            ).pngData()
        ).write(to: newURL)

        let match = CaptureDuplicateDetector.strongestMatch(
            candidates: [
                candidate(
                    name: "本次虚构报告.png",
                    sha256: try CaptureVaultService.sha256File(at: newURL),
                    visualURL: newURL,
                    ocrText: newText
                )
            ],
            records: [
                CaptureDuplicateRecordSnapshot(
                    id: UUID(),
                    title: "历史虚构报告",
                    eventDate: CTDate.make(2026, 3, 12),
                    ocrText: oldText,
                    attachments: [
                        CaptureDuplicateAttachmentSnapshot(
                            id: UUID(),
                            sha256: try CaptureVaultService.sha256File(at: oldURL),
                            visualURL: oldURL,
                            pixelWidth: 1_200,
                            pixelHeight: 1_600
                        )
                    ]
                )
            ]
        )

        #expect(match == nil)
    }

    @MainActor
    @Test("检测服务只读取目标成员记录并严格隔离其他成员")
    func serviceIsPatientScoped() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let currentPatient = Patient(displayName: "虚构成员甲")
        let otherPatient = Patient(displayName: "虚构成员乙")
        context.insert(currentPatient)
        context.insert(otherPatient)
        context.insert(
            MedicalRecord(
                patientId: otherPatient.id,
                title: "乙的虚构报告",
                eventDate: CTDate.make(2026, 3, 12),
                ocrText: fictionalOCR
            )
        )
        try context.save()

        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let image = reportImage(title: "虚构新报告", lines: ["仅用于隔离测试"])
        let batchID = UUID()
        let staged = try vault.stagePhotoData(
            try #require(image.pngData()),
            batchID: batchID,
            displayName: "虚构新报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )

        let match = try await CaptureDuplicateDetectionService(
            context: context,
            vault: vault
        ).scan(
            patientID: currentPatient.id,
            stagedAssets: [staged],
            ocrTextByAssetID: [staged.id: fictionalOCR]
        )

        #expect(match == nil)
    }

    @MainActor
    @Test("页面引用不存在的批次 journal 时检测失败关闭")
    func serviceFailsClosedWhenJournalIsMissing() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let page = M3CapturePageAsset(
            stagedAssetID: UUID(),
            batchID: UUID(),
            displayName: "缺失批次的虚构报告.png",
            sourceOrder: 0,
            ocrText: fictionalOCR
        )

        await #expect(throws: CaptureVaultError.invalidBatch) {
            _ = try await CaptureDuplicateDetectionService(
                context: context,
                vault: vault
            ).scan(
                patientID: UUID(),
                pages: [page]
            )
        }
    }

    @MainActor
    @Test("页面引用 journal 中不存在的 stagedAsset 时检测失败关闭")
    func serviceFailsClosedWhenStagedAssetIsMissing() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let batchID = UUID()
        let image = reportImage(title: "虚构已暂存报告", lines: ["有效页面"])
        _ = try vault.stagePhotoData(
            try #require(image.pngData()),
            batchID: batchID,
            displayName: "有效页面.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let page = M3CapturePageAsset(
            stagedAssetID: UUID(),
            batchID: batchID,
            displayName: "journal 中不存在的页面.png",
            sourceOrder: 0,
            ocrText: fictionalOCR
        )

        await #expect(
            throws: CaptureDuplicateDetectionError.invalidCaptureInput
        ) {
            _ = try await CaptureDuplicateDetectionService(
                context: context,
                vault: vault
            ).scan(
                patientID: UUID(),
                pages: [page]
            )
        }
    }

    @MainActor
    @Test("视觉预览缺失时回退原图继续查重")
    func serviceFallsBackToOriginalWhenPreviewIsMissing() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let image = largeReportImage()
        let batchID = UUID()
        let png = try vault.stagePhotoData(
            try #require(image.pngData()),
            batchID: batchID,
            displayName: "虚构大图原件.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let jpeg = try vault.stagePhotoData(
            try #require(image.jpegData(compressionQuality: 0.68)),
            batchID: batchID,
            displayName: "虚构大图重编码.jpg",
            preferredExtension: "jpg",
            uniformTypeIdentifier: "public.jpeg"
        )
        let previewPath = try #require(jpeg.previewRelativePath)
        try FileManager.default.removeItem(at: vault.url(for: previewPath))
        #expect(
            FileManager.default.fileExists(
                atPath: try vault.url(for: jpeg.originalRelativePath).path
            )
        )

        let match = try #require(
            try await CaptureDuplicateDetectionService(
                context: context,
                vault: vault
            ).scan(
                patientID: UUID(),
                stagedAssets: [png, jpeg],
                ocrTextByAssetID: [:]
            )
        )

        #expect(match.evidence == .visualContentHash)
        #expect(match.scope == .currentImport)
    }

    @MainActor
    @Test("同成员历史图片原件不可读时检测失败关闭而非静默放行")
    func serviceFailsClosedWhenHistoricalOriginalIsUnreadable() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patientID = UUID()
        let record = MedicalRecord(
            patientId: patientID,
            title: "虚构历史报告",
            eventDate: CTDate.make(2026, 7, 30)
        )
        let attachmentID = UUID()
        let missingPath =
            "members/\(patientID.uuidString)/records/\(record.id.uuidString)"
            + "/attachments/\(attachmentID.uuidString)/original.png"
        let attachment = try Attachment.verified(
            id: attachmentID,
            patientId: patientID,
            recordId: record.id,
            originalRelativePath: missingPath,
            displayFileName: "已损坏的虚构历史报告.png",
            kind: .image,
            pageIndex: 0,
            uniformTypeIdentifier: "public.png",
            byteCount: 128,
            sha256: String(repeating: "f", count: 64),
            importSource: .fixture,
            pixelWidth: 1_200,
            pixelHeight: 1_600
        )
        try record.bindAttachment(attachment)
        context.insert(record)
        try context.save()

        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let staged = try vault.stagePhotoData(
            try #require(
                reportImage(
                    title: "虚构本次报告",
                    lines: ["与历史 SHA 不同且 OCR 为空"]
                ).pngData()
            ),
            batchID: UUID(),
            displayName: "虚构本次报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )

        await #expect(
            throws: CaptureDuplicateDetectionError.invalidCaptureInput
        ) {
            _ = try await CaptureDuplicateDetectionService(
                context: context,
                vault: vault
            ).scan(
                patientID: patientID,
                stagedAssets: [staged],
                ocrTextByAssetID: [:]
            )
        }
    }

    @MainActor
    @Test("派生指纹损坏时各重建一次，重开数据库后不再计算")
    func derivedArtifactsRebuildOnceAndSurviveReopen() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("derived.sqlite")
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let patientID = UUID()
        let recordID = UUID()
        let attachmentID = UUID()
        let relativePath =
            "members/\(patientID.uuidString)/records/\(recordID.uuidString)"
            + "/attachments/\(attachmentID.uuidString)/original.png"
        let originalURL = try vault.url(for: relativePath)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalData = try #require(
            reportImage(title: "虚构历史报告", lines: ["派生数据重建测试"]).pngData()
        )
        try originalData.write(to: originalURL)
        let originalSHA = try CaptureVaultService.sha256File(at: originalURL)
        let corrupted = CaptureAttachmentDerivedArtifactSet(
            sourceSHA256: originalSHA,
            perceptualHashPayload: Data([0x01, 0x02]),
            perceptualHashAlgorithmVersion:
                CapturePerceptualImageHash.algorithmIdentifier,
            visionFeaturePrintPayload: Data([0x03, 0x04]),
            visionFeaturePrintAlgorithmVersion:
                CaptureVisionImageFingerprint.algorithmIdentifier
        )
        let textIndex = Data("虚构本地索引".utf8)
        do {
            let container = try TestSupport.persistentContainer(at: storeURL)
            let record = MedicalRecord(
                id: recordID,
                patientId: patientID,
                title: "虚构历史报告",
                eventDate: CTDate.make(2026, 7, 1)
            )
            record.replaceDerivedTextIndex(
                payload: textIndex,
                algorithmVersion: "carethread-bm25-fixture-v1",
                sourceRevision: record.contentRevision
            )
            let attachment = try Attachment.verified(
                id: attachmentID,
                patientId: patientID,
                recordId: recordID,
                originalRelativePath: relativePath,
                displayFileName: "虚构历史报告.png",
                kind: .image,
                pageIndex: 0,
                uniformTypeIdentifier: "public.png",
                byteCount: Int64(originalData.count),
                sha256: originalSHA,
                importSource: .fixture,
                pixelWidth: 1_200,
                pixelHeight: 1_600,
                derivedArtifacts: corrupted
            )
            try record.bindAttachment(attachment)
            container.mainContext.insert(record)
            try container.mainContext.save()

            let counters = DerivedArtifactCallCounters()
            let staged = try vault.stagePhotoData(
                try #require(
                    reportImage(
                        title: "虚构新报告",
                        lines: ["重启语义验证"]
                    ).pngData()
                ),
                batchID: UUID(),
                displayName: "虚构新报告.png",
                preferredExtension: "png",
                uniformTypeIdentifier: "public.png"
            )
            _ = try await CaptureDuplicateDetectionService(
                context: container.mainContext,
                vault: vault,
                artifactComputer: countingComputer(counters)
            ).scan(
                patientID: patientID,
                stagedAssets: [staged],
                ocrTextByAssetID: [:]
            )
            #expect(counters.perceptualHashCalls == 1)
            #expect(counters.visionFeaturePrintCalls == 1)
        }

        do {
            let reopened = try TestSupport.persistentContainer(at: storeURL)
            let counters = DerivedArtifactCallCounters()
            let staged = try vault.stagePhotoData(
                try #require(
                    reportImage(
                        title: "虚构第二份新报告",
                        lines: ["跨服务实例验证"]
                    ).pngData()
                ),
                batchID: UUID(),
                displayName: "虚构第二份新报告.png",
                preferredExtension: "png",
                uniformTypeIdentifier: "public.png"
            )
            _ = try await CaptureDuplicateDetectionService(
                context: reopened.mainContext,
                vault: vault,
                artifactComputer: countingComputer(counters)
            ).scan(
                patientID: patientID,
                stagedAssets: [staged],
                ocrTextByAssetID: [:]
            )
            #expect(counters.perceptualHashCalls == 0)
            #expect(counters.visionFeaturePrintCalls == 0)
            let attachments = try reopened.mainContext.fetch(
                FetchDescriptor<Attachment>()
            )
            let persisted = try #require(
                attachments.first(where: { $0.id == attachmentID })
            )
            #expect(persisted.derivedArtifacts.sourceSHA256 == originalSHA)
            #expect(
                persisted.derivedArtifacts.hasCurrentPerceptualHash(
                    sourceSHA256: originalSHA
                )
            )
            #expect(
                persisted.derivedArtifacts.hasCurrentVisionFeaturePrint(
                    sourceSHA256: originalSHA
                )
            )
            let persistedRecord = try #require(
                try reopened.mainContext.fetch(FetchDescriptor<MedicalRecord>())
                    .first(where: { $0.id == recordID })
            )
            #expect(persistedRecord.derivedTextIndexPayload == textIndex)
            #expect(
                persistedRecord.derivedTextIndexAlgorithmVersion
                    == "carethread-bm25-fixture-v1"
            )
            #expect(persistedRecord.derivedTextIndexSourceRevision == 0)
        }
    }

    @Test("Vision 数值向量持久化可往返且距离确定")
    func visionFeatureVectorPersistenceRoundTrip() throws {
        let vector = try #require(
            CaptureVisionFeatureVector(values: [0.10, -0.25, 0.50, 0.75])
        )
        let payload = try #require(
            CaptureAttachmentDerivedArtifactCodec.encodeVisionFeaturePrint(
                vector
            )
        )
        let decoded = try #require(
            CaptureAttachmentDerivedArtifactCodec.decodeVisionFeaturePrint(
                payload
            )
        )
        #expect(decoded == vector)
        #expect(
            CaptureVisionImageFingerprint.distance(vector, decoded) == 0
        )
        let shifted = try #require(
            CaptureVisionFeatureVector(values: [0.40, -0.25, 0.90, 0.75])
        )
        #expect(
            abs(
                try #require(
                    CaptureVisionImageFingerprint.distance(vector, shifted)
                ) - 0.5
            ) < 0.000_001
        )
    }

    @MainActor
    @Test("300 附件查重不重算历史指纹并保持回归时延")
    func threeHundredAttachmentLookupPerformanceBaseline() async throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let patientID = UUID()
        let fixtureImage = reportImage(
            title: "虚构历史报告",
            lines: ["300 附件性能基线"]
        )
        let fixtureData = try #require(
            fixtureImage.pngData()
        )
        let candidateData = try #require(
            fixtureImage.jpegData(compressionQuality: 0.71)
        )
        let historicalSHA = CaptureVaultService.sha256(fixtureData)
        let candidateSHA = CaptureVaultService.sha256(candidateData)
        #expect(historicalSHA != candidateSHA)
        var staged = try vault.stagePhotoData(
            candidateData,
            batchID: UUID(),
            displayName: "虚构候选.jpg",
            preferredExtension: "jpg",
            uniformTypeIdentifier: "public.jpeg"
        )
        let stagedArtifacts = try #require(staged.derivedArtifacts)
        let candidateHash = try #require(
            CaptureAttachmentDerivedArtifactCodec.decodePerceptualHash(
                stagedArtifacts.perceptualHashPayload
            )
        )
        let forcedMissHash = CapturePerceptualHashValue(
            dctHashes: candidateHash.dctHashes.map { ~$0 },
            blockHashes: candidateHash.blockHashes.map { ~$0 },
            differenceHashes: candidateHash.differenceHashes.map { ~$0 }
        )
        let syntheticVisionVector = try #require(
            CaptureVisionFeatureVector(
                values: (0..<512).map { Float($0 % 17) / 17 }
            )
        )
        let syntheticVisionPayload = try #require(
            CaptureAttachmentDerivedArtifactCodec.encodeVisionFeaturePrint(
                syntheticVisionVector
            )
        )
        let candidateArtifacts = CaptureAttachmentDerivedArtifactSet(
            sourceSHA256: candidateSHA,
            perceptualHashPayload: stagedArtifacts.perceptualHashPayload,
            perceptualHashAlgorithmVersion:
                CapturePerceptualImageHash.algorithmIdentifier,
            visionFeaturePrintPayload: syntheticVisionPayload,
            visionFeaturePrintAlgorithmVersion:
                CaptureVisionImageFingerprint.algorithmIdentifier
        )
        staged = try vault.updateStagedDerivedArtifacts(
            batchID: staged.batchID,
            assetID: staged.id,
            artifacts: candidateArtifacts
        )
        // Persist the candidate's valid Vision vector on the sole recent
        // synthetic history row so the benchmark deterministically reaches
        // and matches at level four after SHA, pHash and OCR all miss.
        let historicalArtifacts = CaptureAttachmentDerivedArtifactSet(
            sourceSHA256: historicalSHA,
            perceptualHashPayload:
                CaptureAttachmentDerivedArtifactCodec.encodePerceptualHash(
                    forcedMissHash
                ),
            perceptualHashAlgorithmVersion:
                CapturePerceptualImageHash.algorithmIdentifier,
            visionFeaturePrintPayload: syntheticVisionPayload,
            visionFeaturePrintAlgorithmVersion:
                CaptureVisionImageFingerprint.algorithmIdentifier
        )
        #expect(
            candidateArtifacts.hasCurrentVisionFeaturePrint(
                sourceSHA256: candidateSHA
            )
        )
        #expect(
            historicalArtifacts.hasCurrentVisionFeaturePrint(
                sourceSHA256: historicalSHA
            )
        )
        let candidatePrint = try #require(
            CaptureAttachmentDerivedArtifactCodec.decodeVisionFeaturePrint(
                candidateArtifacts.visionFeaturePrintPayload
            )
        )
        let historicalPrint = try #require(
            CaptureAttachmentDerivedArtifactCodec.decodeVisionFeaturePrint(
                historicalArtifacts.visionFeaturePrintPayload
            )
        )
        #expect(
            CaptureVisionImageFingerprint.distance(
                candidatePrint,
                historicalPrint
            ) == 0
        )
        for index in 0..<300 {
            let recordID = UUID()
            let attachmentID = UUID()
            let path =
                "members/\(patientID.uuidString)/records/\(recordID.uuidString)"
                + "/attachments/\(attachmentID.uuidString)/original.png"
            let url = try vault.url(for: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fixtureData.write(to: url)
            let record = MedicalRecord(
                id: recordID,
                patientId: patientID,
                title: "虚构历史报告 \(index)",
                eventDate: index == 299
                    ? CTDate.make(2026, 7, 1)
                    : CTDate.make(2020, 1, 1)
            )
            let historical = try Attachment.verified(
                id: attachmentID,
                patientId: patientID,
                recordId: recordID,
                originalRelativePath: path,
                displayFileName: "虚构历史报告-\(index).png",
                kind: .image,
                pageIndex: 0,
                uniformTypeIdentifier: "public.png",
                byteCount: Int64(fixtureData.count),
                sha256: historicalSHA,
                importSource: .fixture,
                pixelWidth: 1_200,
                pixelHeight: 1_600,
                derivedArtifacts: historicalArtifacts
            )
            try record.bindAttachment(historical)
            context.insert(record)
        }
        try context.save()

        let records = try context.fetch(FetchDescriptor<MedicalRecord>())
        let visionIDs = CaptureDuplicatePerformancePolicy
            .visionEligibleAttachmentIDs(
                records: records,
                now: CTDate.make(2026, 7, 31)
            )
        #expect(visionIDs.count == 1)

        let counters = DerivedArtifactCallCounters()
        var samples: [Double] = []
        var lastMatch: CaptureDuplicateMatch?
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            lastMatch = try await CaptureDuplicateDetectionService(
                context: context,
                vault: vault,
                artifactComputer: countingComputer(counters)
            ).scan(
                patientID: patientID,
                stagedAssets: [staged],
                ocrTextByAssetID: [:]
            )
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        let sorted = samples.sorted()
        let medianMilliseconds = sorted[sorted.count / 2]
        let p95Milliseconds = sorted[sorted.count - 1]
        print(
            "BATCH3_PERF_300_ATTACHMENTS_MEDIAN_MS="
                + String(format: "%.2f", medianMilliseconds)
                + " P95_MS=" + String(format: "%.2f", p95Milliseconds)
        )
        #expect(lastMatch?.evidence == .visualContentHash)
        #expect(counters.perceptualHashCalls == 0)
        #expect(counters.visionFeaturePrintCalls == 0)
        #expect(p95Milliseconds < 2_000)
    }

    @Test("Vision 降级在 201 张启用且精确覆盖最近 24 个月")
    func visionFallbackBoundaryIsExplicit() throws {
        #expect(
            !CaptureDuplicatePerformancePolicy.usesRecentVisionWindow(
                imageAttachmentCount: 200
            )
        )
        #expect(
            CaptureDuplicatePerformancePolicy.usesRecentVisionWindow(
                imageAttachmentCount: 201
            )
        )
        let now = CTDate.make(2026, 7, 31)
        let cutoff = try #require(
            CaptureDuplicatePerformancePolicy.recentVisionCutoff(now: now)
        )
        #expect(cutoff == CTDate.make(2024, 7, 31))
        #expect(
            CaptureDuplicatePerformancePolicy.isVisionEventEligible(
                cutoff,
                cutoff: cutoff
            )
        )
        #expect(
            !CaptureDuplicatePerformancePolicy.isVisionEventEligible(
                cutoff.addingTimeInterval(-1),
                cutoff: cutoff
            )
        )
    }

    private var fictionalOCR: String {
        """
        虚构市第一医院甲状腺功能检验报告
        报告编号 CT-0007 检验日期 2026-03-12
        TSH 0.08 mIU/L 参考范围 0.27-4.20
        FT4 24.6 pmol/L 参考范围 12.0-22.0
        本内容完全虚构，仅供自动化测试。
        """
    }

    private func countingComputer(
        _ counters: DerivedArtifactCallCounters
    ) -> CaptureAttachmentDerivedArtifactComputer {
        CaptureAttachmentDerivedArtifactComputer(
            makePerceptualHash: { url in
                counters.recordPerceptualHashCall()
                return CapturePerceptualImageHash.make(url: url)
            },
            makeVisionFeaturePrint: { url in
                counters.recordVisionFeaturePrintCall()
                return CaptureVisionImageFingerprint.make(url: url)
            }
        )
    }

    private var fictionalFourPageOCR: [String] {
        [
            """
            虚构市康宁医院住院记录 第一页
            住院号 ZY-20260418 姓名 测试甲 入院日期 2026-04-18
            主诉为间断乏力两周，既往情况与本次虚构测试无真实人物关联。
            入院查体记录体温、脉搏、呼吸及血压，详细数值仅用于模拟长页文本。
            初步安排包括常规检验与生活记录，本页不构成任何诊断建议。
            """,
            """
            虚构市康宁医院住院记录 第二页
            住院号 ZY-20260418 姓名 测试甲 入院日期 2026-04-18
            检验经过记录血常规、生化及电解质项目，所有结果均为虚构样本。
            当日饮食、睡眠与活动情况由测试数据生成，用于验证多页报告归档。
            复核人员记录内容完整，本页不构成任何诊断建议或治疗依据。
            """,
            """
            虚构市康宁医院住院记录 第三页
            住院号 ZY-20260418 姓名 测试甲 入院日期 2026-04-18
            过程记录包含一次影像检查预约及两次指标复核，项目名称均为虚构。
            页面保留独立段落与连续上下文，用于模拟单页截图再次导入的情形。
            资料整理人已核对页码，本页不构成任何诊断建议或治疗依据。
            """,
            """
            虚构市康宁医院住院记录 第四页
            住院号 ZY-20260418 姓名 测试甲 入院日期 2026-04-18
            出院整理包括报告清单、随身资料和后续自主管理事项，内容均为虚构。
            本次测试只验证四页长度相近且文字互异时的重复内容包含检索能力。
            归档人员确认页数完整，本页不构成任何诊断建议或治疗依据。
            """
        ]
    }

    private func candidate(
        name: String,
        sha256: String,
        visualURL: URL? = nil,
        ocrText: String = ""
    ) -> CaptureDuplicateCandidateSnapshot {
        CaptureDuplicateCandidateSnapshot(
            id: UUID(),
            displayName: name,
            sha256: sha256,
            visualURL: visualURL,
            pixelWidth: 1_200,
            pixelHeight: 1_600,
            ocrText: ocrText
        )
    }

    private func reportImage(title: String, lines: [String]) -> UIImage {
        UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 1_600)
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_600))
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(4)
            context.cgContext.stroke(
                CGRect(x: 70, y: 70, width: 1_060, height: 1_460)
            )
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            title.draw(
                at: CGPoint(x: 120, y: 150),
                withAttributes: attributes
            )
            let lineAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34),
                .foregroundColor: UIColor.darkGray
            ]
            for (index, line) in lines.enumerated() {
                line.draw(
                    at: CGPoint(x: 120, y: 300 + CGFloat(index * 120)),
                    withAttributes: lineAttributes
                )
            }
        }
    }

    private func simulatedRetake(of image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 1_600)
        ).image { context in
            UIColor(white: 0.78, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_600))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 600, y: 800)
            context.cgContext.rotate(by: 0.008)
            context.cgContext.translateBy(x: -600, y: -800)
            image.draw(
                in: CGRect(x: 55, y: 72, width: 1_090, height: 1_454),
                blendMode: .normal,
                alpha: 0.93
            )
            context.cgContext.restoreGState()
            UIColor(white: 0.92, alpha: 0.08).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_600))
        }
    }

    private func verticallyCroppedRetake(of image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 1_300)
        ).image { context in
            UIColor(white: 0.84, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_300))
            image.draw(
                in: CGRect(x: 0, y: -150, width: 1_200, height: 1_600),
                blendMode: .normal,
                alpha: 0.94
            )
        }
    }

    private func largeReportImage() -> UIImage {
        UIGraphicsImageRenderer(
            size: CGSize(width: 3_200, height: 4_000)
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_200, height: 4_000))
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(10)
            context.cgContext.stroke(
                CGRect(x: 160, y: 160, width: 2_880, height: 3_680)
            )
            "虚构市康宁医院 检验报告".draw(
                at: CGPoint(x: 320, y: 420),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 116, weight: .bold),
                    .foregroundColor: UIColor.black
                ]
            )
            for (index, line) in [
                "报告编号 BIG-0042",
                "检验日期 2026-04-18",
                "虚构指标 A 12.4  虚构指标 B 5.8",
                "仅用于预览回退自动化测试"
            ].enumerated() {
                line.draw(
                    at: CGPoint(x: 320, y: 850 + CGFloat(index * 330)),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 82),
                        .foregroundColor: UIColor.darkGray
                    ]
                )
            }
        }
    }

    private func unrelatedChartImage() -> UIImage {
        UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 1_600)
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_600))
            UIColor.systemYellow.setFill()
            context.cgContext.fillEllipse(
                in: CGRect(x: 120, y: 150, width: 900, height: 900)
            )
            UIColor.systemBlue.setStroke()
            context.cgContext.setLineWidth(80)
            context.cgContext.move(to: CGPoint(x: 100, y: 1_450))
            context.cgContext.addLine(to: CGPoint(x: 420, y: 1_100))
            context.cgContext.addLine(to: CGPoint(x: 740, y: 1_360))
            context.cgContext.addLine(to: CGPoint(x: 1_080, y: 980))
            context.cgContext.strokePath()
        }
    }

    private func rotatedQuarterTurn(of image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(
            size: CGSize(width: image.size.height, height: image.size.width)
        ).image { _ in
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.translateBy(x: image.size.height, y: 0)
            context.rotate(by: .pi / 2)
            image.draw(
                in: CGRect(origin: .zero, size: image.size)
            )
        }
    }
}

private final class DerivedArtifactCallCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var perceptualHashCount = 0
    private var visionFeaturePrintCount = 0

    var perceptualHashCalls: Int {
        lock.withLock { perceptualHashCount }
    }

    var visionFeaturePrintCalls: Int {
        lock.withLock { visionFeaturePrintCount }
    }

    func recordPerceptualHashCall() {
        lock.withLock { perceptualHashCount += 1 }
    }

    func recordVisionFeaturePrintCall() {
        lock.withLock { visionFeaturePrintCount += 1 }
    }
}
