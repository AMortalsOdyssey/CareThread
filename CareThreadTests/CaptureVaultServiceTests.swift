import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import CareThread

// Xcode 26.6 起 Swift Testing 自带 Attachment 类型，与 App 模型撞名；本文件内统一指回 App 模型。
private typealias Attachment = CareThread.Attachment

@MainActor
struct CaptureVaultServiceTests {
    @Test("48MP 原件只计算 3000 工作图尺寸且不改原始字节与哈希")
    func previewPolicy_downsamplesDimensionsWithoutTouchingOriginal() {
        let original = Data("immutable-original-fixture".utf8)
        let originalCount = original.count
        let originalHash = CaptureVaultService.sha256(original)

        let target = CaptureImagePreviewPolicy.targetDimensions(
            width: 8_000,
            height: 6_000
        )

        #expect(target == CapturePreviewDimensions(width: 3_000, height: 2_250))
        #expect(original.count == originalCount)
        #expect(CaptureVaultService.sha256(original) == originalHash)
    }

    @Test("高熵大图多页逐页暂存且原件顺序哈希与 3000px 预览保持正确")
    func highEntropyBulkStaging_isSinglePageBoundedAndOrdered() async throws {
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        let batchID = UUID()
        let probe = CaptureStagingProbe()
        let expectedHashes = CaptureExpectedHashStore()
        let pageCount = 8

        let assets = try await CaptureAssetStagingWorker.stagePages(
            count: pageCount,
            vaultRootURL: root,
            batchID: batchID,
            preferredExtension: "jpg",
            uniformTypeIdentifier: UTType.jpeg.identifier,
            displayName: { "高熵虚构页-\($0).jpg" },
            dataForPage: { index in
                let size = index == 0
                    ? (width: 4_096, height: 3_072)
                    : (width: 1_024, height: 768)
                let data = try makeDeterministicHighEntropyJPEG(
                    width: size.width,
                    height: size.height,
                    seed: UInt64(index + 1)
                )
                expectedHashes.set(
                    CaptureVaultService.sha256(data),
                    for: index
                )
                return data
            },
            observer: { event in
                probe.record(event)
            }
        )

        let vault = try CaptureVaultService(rootURL: root)
        #expect(assets.count == pageCount)
        #expect(probe.maximumInFlight == 1)
        #expect(probe.inFlight == 0)
        #expect(!probe.observedMainThread)
        #expect(
            assets.map(\.displayName)
                == (0..<pageCount).map { "高熵虚构页-\($0).jpg" }
        )
        #expect(try vault.journal(batchID: batchID).assets == assets)
        for (index, asset) in assets.enumerated() {
            let originalURL = try vault.url(for: asset.originalRelativePath)
            #expect(
                try CaptureVaultService.sha256File(at: originalURL)
                    == expectedHashes.value(for: index)
            )
        }
        let previewPath = try #require(assets[0].previewRelativePath)
        let previewURL = try vault.url(for: previewPath)
        let previewSource = try #require(
            CGImageSourceCreateWithURL(previewURL as CFURL, nil)
        )
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(previewSource, 0, nil)
                as? [CFString: Any]
        )
        let width = try #require(
            properties[kCGImagePropertyPixelWidth] as? Int
        )
        let height = try #require(
            properties[kCGImagePropertyPixelHeight] as? Int
        )
        #expect(max(width, height) == 3_000)
    }

    @Test("多页暂存中途失败会删除本次已落盘前缀")
    func bulkStagingFailure_discardsStagedPrefix() async throws {
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        let batchID = UUID()

        await #expect(throws: CaptureStagingFixtureError.injected) {
            _ = try await CaptureAssetStagingWorker.stagePages(
                count: 6,
                vaultRootURL: root,
                batchID: batchID,
                preferredExtension: "jpg",
                uniformTypeIdentifier: UTType.jpeg.identifier,
                displayName: { "失败清理页-\($0).jpg" },
                dataForPage: { index in
                    if index == 3 {
                        throw CaptureStagingFixtureError.injected
                    }
                    return try makeDeterministicHighEntropyJPEG(
                        width: 640,
                        height: 480,
                        seed: UInt64(index + 10)
                    )
                }
            )
        }

        let vault = try CaptureVaultService(rootURL: root)
        let journal = try vault.journal(batchID: batchID)
        #expect(journal.assets.isEmpty)
        let batchURL = root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: batchURL,
            includingPropertiesForKeys: nil
        )
        #expect(remaining.map(\.lastPathComponent) == ["journal.json"])
    }

    @Test("三页 PDF 暂存为一个原件并记录真实页数")
    func multiPagePDF_isOneStagedOriginalWithActualPageCount() throws {
        let directory = try TestSupport.temporaryDirectory()
        let pdfURL = directory.appendingPathComponent("虚构三页报告.pdf")
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        try renderer.writePDF(to: pdfURL) { context in
            for _ in 0..<3 {
                context.beginPage()
            }
        }
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let batchID = UUID()

        let staged = try vault.stageFile(at: pdfURL, batchID: batchID)
        let journal = try vault.journal(batchID: batchID)

        #expect(staged.kind == .pdf)
        #expect(staged.pageCount == 3)
        #expect(journal.assets.count == 1)
        #expect(journal.assets.first == staged)
        let finalized = try vault.finalize(
            asset: staged,
            patientID: UUID(),
            recordID: UUID()
        )
        #expect(
            FileManager.default.fileExists(
                atPath: try vault.url(for: finalized.finalRelativePath).path
            )
        )
    }

    @Test("22 页先建议拆分，用户明确确认后可以继续")
    func largeDocument_requiresExplicitSoftLimitAcknowledgement() {
        let patient = Patient(name: "长报告成员", reportName: "虚构姓名")
        let controller = M3CaptureFlowController(patient: patient)
        controller.documents = [
            M3CaptureDocument(
                pages: (0..<22).map {
                    M3CapturePageAsset(
                        displayName: "虚构页 \($0 + 1)",
                        sourceOrder: $0
                    )
                }
            )
        ]

        controller.markGroupingConfirmed()
        #expect(!controller.groupingConfirmed)
        #expect(controller.errorMessage == Copy.Capture.largeDocumentWarning)

        controller.acknowledgeLargeDocument()
        controller.markGroupingConfirmed()
        #expect(controller.groupingConfirmed)
    }

    @Test("同一多页 PDF 不能在工作台跨报告拆分")
    func multiPagePDF_cannotCrossDocumentBoundary() {
        let patient = Patient(name: "PDF 成员", reportName: "虚构姓名")
        let controller = M3CaptureFlowController(patient: patient)
        let stagedID = UUID()
        controller.documents = [
            M3CaptureDocument(
                pages: [
                    M3CapturePageAsset(
                        stagedAssetID: stagedID,
                        displayName: "PDF 第 1 页",
                        kind: .pdf,
                        sourceOrder: 0,
                        pdfPageIndex: 0
                    ),
                    M3CapturePageAsset(
                        displayName: "其他图片",
                        sourceOrder: 1
                    ),
                    M3CapturePageAsset(
                        stagedAssetID: stagedID,
                        displayName: "PDF 第 2 页",
                        kind: .pdf,
                        sourceOrder: 2,
                        pdfPageIndex: 1
                    )
                ]
            )
        ]

        controller.split(documentIndex: 0, beforePageIndex: 1)

        #expect(controller.documents.count == 1)
        #expect(controller.errorMessage == Copy.Capture.pdfBoundaryLocked)
    }

    @Test("用户手动拆分成为后续 OCR 分组的权威边界")
    func manualSplit_marksGroupingAsUserEdited() {
        let patient = Patient(name: "分组成员", reportName: "虚构姓名")
        let controller = M3CaptureFlowController(patient: patient)
        controller.documents = [
            M3CaptureDocument(
                pages: [
                    M3CapturePageAsset(displayName: "报告一", sourceOrder: 0),
                    M3CapturePageAsset(displayName: "报告二", sourceOrder: 1)
                ]
            )
        ]

        controller.split(documentIndex: 0, beforePageIndex: 1)

        #expect(controller.documents.count == 2)
        #expect(controller.hasManualGroupingEdits)
    }

    @Test("确认分组时再次拒绝同一 PDF 分属两份报告")
    func groupingConfirmation_rejectsPDFSharedAcrossRecords() {
        let patient = Patient(name: "PDF 成员", reportName: "虚构姓名")
        let controller = M3CaptureFlowController(patient: patient)
        let stagedID = UUID()
        controller.documents = [
            M3CaptureDocument(
                pages: [
                    M3CapturePageAsset(
                        stagedAssetID: stagedID,
                        displayName: "PDF 第 1 页",
                        kind: .pdf,
                        sourceOrder: 0,
                        pdfPageIndex: 0
                    )
                ]
            ),
            M3CaptureDocument(
                pages: [
                    M3CapturePageAsset(
                        stagedAssetID: stagedID,
                        displayName: "PDF 第 2 页",
                        kind: .pdf,
                        sourceOrder: 1,
                        pdfPageIndex: 1
                    )
                ]
            )
        ]

        controller.markGroupingConfirmed()

        #expect(!controller.groupingConfirmed)
        #expect(controller.errorMessage == Copy.Capture.pdfBoundaryLocked)
    }

    @Test("Vault 暂存原件预览与最终文件都显式排除系统备份")
    func backupExclusion_isAppliedAndVerifiedAtEveryStage() throws {
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        let vault = try CaptureVaultService(rootURL: root)
        let batchID = UUID()
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 3_100, height: 16)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(
                CGRect(x: 0, y: 0, width: 3_100, height: 16)
            )
        }
        let staged = try vault.stagePhotoData(
            try #require(image.pngData()),
            batchID: batchID,
            displayName: "虚构报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let previewPath = try #require(staged.previewRelativePath)

        #expect(try isExcluded(root))
        #expect(try isExcluded(root.appendingPathComponent("staging")))
        #expect(try isExcluded(
            root.appendingPathComponent("staging/\(batchID.uuidString)")
        ))
        #expect(try isExcluded(try vault.url(for: staged.originalRelativePath)))
        #expect(try isExcluded(try vault.url(for: previewPath)))

        let final = try vault.finalize(
            asset: staged,
            patientID: UUID(),
            recordID: UUID()
        )
        #expect(try isExcluded(try vault.url(for: final.finalRelativePath)))
        #expect(try isExcluded(
            try vault.url(for: try #require(final.finalPreviewRelativePath))
        ))
    }

    @Test("成员创建先预配置隔离 Vault，数据库失败时可完整回滚")
    func memberVaultProvisioning_isProtectedAndRollbackIsComplete() throws {
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        let vault = try CaptureVaultService(rootURL: root)
        let patientID = UUID()
        let memberRoot = root.appendingPathComponent(
            "members/\(patientID.uuidString)",
            isDirectory: true
        )
        let recordsRoot = memberRoot.appendingPathComponent(
            "records",
            isDirectory: true
        )

        try vault.provisionVault(for: patientID)

        #expect(FileManager.default.fileExists(atPath: recordsRoot.path))
        #expect(try isExcluded(memberRoot))
        #expect(try isExcluded(recordsRoot))

        vault.rollbackVault(for: patientID)

        #expect(!FileManager.default.fileExists(atPath: memberRoot.path))
    }

    @Test("暂存原件字节或长度被篡改时拒绝进入成员 Vault")
    func finalize_rejectsTamperedStagedOriginal() throws {
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        let vault = try CaptureVaultService(rootURL: root)
        let batchID = UUID()
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 16, height: 16)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let staged = try vault.stagePhotoData(
            try #require(image.pngData()),
            batchID: batchID,
            displayName: "虚构报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let source = try vault.url(for: staged.originalRelativePath)
        try Data("tampered".utf8).write(to: source)

        #expect(throws: CaptureVaultError.integrityMismatch) {
            _ = try vault.finalize(
                asset: staged,
                patientID: UUID(),
                recordID: UUID()
            )
        }
    }

    @Test("不接受未登记在批次日志中的伪造暂存资产")
    func finalize_rejectsForgedAssetMetadata() throws {
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        let vault = try CaptureVaultService(rootURL: root)
        let staged = try vault.stagePhotoData(
            try #require(
                UIGraphicsImageRenderer(
                    size: CGSize(width: 16, height: 16)
                ).image { context in
                    UIColor.white.setFill()
                    context.cgContext.fill(
                        CGRect(x: 0, y: 0, width: 16, height: 16)
                    )
                }.pngData()
            ),
            batchID: UUID(),
            displayName: "虚构报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let forged = StagedCaptureAsset(
            id: staged.id,
            batchID: staged.batchID,
            originalRelativePath: staged.originalRelativePath,
            previewRelativePath: staged.previewRelativePath,
            displayName: "被替换的文件名.png",
            fileExtension: staged.fileExtension,
            uniformTypeIdentifier: staged.uniformTypeIdentifier,
            kind: staged.kind,
            byteCount: staged.byteCount,
            sha256: staged.sha256,
            pixelWidth: staged.pixelWidth,
            pixelHeight: staged.pixelHeight,
            pageCount: staged.pageCount,
            createdAt: staged.createdAt
        )

        #expect(throws: CaptureVaultError.invalidBatch) {
            _ = try vault.finalize(
                asset: forged,
                patientID: UUID(),
                recordID: UUID()
            )
        }
    }

    @Test("文件移动后数据库未提交的崩溃事务在启动时回滚到 staging")
    func reconciliation_rollsBackMovedFilesWithoutDatabaseCommit() throws {
        let fixture = try makeFinalizationFixture()
        let final = try fixture.vault.finalize(
            asset: fixture.staged,
            patientID: fixture.patientID,
            recordID: fixture.recordID
        )
        var journal = try fixture.vault.journal(
            batchID: fixture.staged.batchID
        )
        journal.finalizationTransactions[0].state = .prepared
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(
            to: try fixture.vault.url(
                for: "staging/\(fixture.staged.batchID.uuidString)/journal.json"
            ),
            options: [.atomic, .completeFileProtection]
        )

        try fixture.vault.reconcilePendingFinalizations(
            context: fixture.container.mainContext
        )

        #expect(!FileManager.default.fileExists(
            atPath: try fixture.vault.url(for: final.finalRelativePath).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: try fixture.vault.url(
                for: fixture.staged.originalRelativePath
            ).path
        ))
        #expect(
            try fixture.vault.journal(
                batchID: fixture.staged.batchID
            ).finalizationTransactions.isEmpty
        )
    }

    @Test("数据库已提交但事务状态未更新时启动对账前滚并完成批次")
    func reconciliation_rollsForwardCommittedDatabaseTransaction() throws {
        let fixture = try makeFinalizationFixture()
        let final = try fixture.vault.finalize(
            asset: fixture.staged,
            patientID: fixture.patientID,
            recordID: fixture.recordID
        )
        let context = fixture.container.mainContext
        let patient = Patient(
            id: fixture.patientID,
            name: "事务成员"
        )
        let record = MedicalRecord(
            id: fixture.recordID,
            patientId: fixture.patientID,
            title: "事务报告",
            eventDate: Date(),
            sourceType: .photo
        )
        let attachment = try Attachment.verified(
            id: fixture.staged.id,
            patientId: fixture.patientID,
            recordId: fixture.recordID,
            originalRelativePath: final.finalRelativePath,
            derivedRelativePath: final.finalPreviewRelativePath,
            displayFileName: fixture.staged.displayName,
            kind: fixture.staged.kind,
            pageIndex: 0,
            uniformTypeIdentifier: fixture.staged.uniformTypeIdentifier,
            byteCount: fixture.staged.byteCount,
            sha256: fixture.staged.sha256,
            importSource: .photoLibrary
        )
        try record.bindAttachment(attachment)
        context.insert(patient)
        context.insert(record)
        try context.save()

        try fixture.vault.reconcilePendingFinalizations(context: context)

        #expect(FileManager.default.fileExists(
            atPath: try fixture.vault.url(for: final.finalRelativePath).path
        ))
        #expect(throws: CaptureVaultError.invalidBatch) {
            _ = try fixture.vault.journal(
                batchID: fixture.staged.batchID
            )
        }
    }

    @Test("删除记录后解锁并清理原件和派生预览")
    func recordDelete_removesImmutableAttachmentFilesAfterDatabaseCommit() throws {
        let fixture = try makeRecordFixture()
        let attachmentID = UUID()
        let paths = try createImmutableFiles(
            vault: fixture.vault,
            patientID: fixture.patient.id,
            recordID: fixture.record.id,
            attachmentID: attachmentID
        )
        let attachment = try verifiedAttachment(
            id: attachmentID,
            patientID: fixture.patient.id,
            recordID: fixture.record.id,
            original: paths.original,
            derived: paths.derived
        )
        try fixture.record.bindAttachment(attachment)
        try fixture.context.save()

        try RecordRepository(
            context: fixture.context,
            fileDeletion: fixture.vault
        ).delete(fixture.record)

        #expect(!FileManager.default.fileExists(
            atPath: try fixture.vault.url(for: paths.original).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: try fixture.vault.url(for: paths.derived).path
        ))
    }

    @Test("附件文件已缺失时删除记录仍成功")
    func recordDelete_missingFilesIsIdempotent() throws {
        let fixture = try makeRecordFixture()
        let attachmentID = UUID()
        let base = "members/\(fixture.patient.id.uuidString)/records/"
            + "\(fixture.record.id.uuidString)/attachments/\(attachmentID.uuidString)"
        let attachment = try verifiedAttachment(
            id: attachmentID,
            patientID: fixture.patient.id,
            recordID: fixture.record.id,
            original: "\(base)/original.pdf",
            derived: "\(base)/preview.jpg"
        )
        try fixture.record.bindAttachment(attachment)
        try fixture.context.save()

        try RecordRepository(
            context: fixture.context,
            fileDeletion: fixture.vault
        ).delete(fixture.record)

        #expect(try fixture.context.fetchCount(
            FetchDescriptor<MedicalRecord>()
        ) == 0)
    }

    @Test("附件不能伪造为另一条记录或成员的 Vault 路径")
    func verifiedAttachment_rejectsCrossRecordAndCrossMemberPaths() throws {
        let patient = Patient(name: "共享成员", reportName: "虚构姓名")
        let first = MedicalRecord(
            patientId: patient.id,
            title: "报告一",
            eventDate: Date()
        )
        let second = MedicalRecord(
            patientId: patient.id,
            title: "报告二",
            eventDate: Date()
        )
        let attachmentID = UUID()
        let firstPath = "members/\(patient.id.uuidString)/records/"
            + "\(first.id.uuidString)/attachments/\(attachmentID.uuidString)"
        let otherPatient = UUID()
        let otherPatientPath = "members/\(otherPatient.uuidString)/records/"
            + "\(second.id.uuidString)/attachments/\(attachmentID.uuidString)"

        #expect(throws: AttachmentValidationError.invalidRelativePath) {
            _ = try Attachment.verified(
                id: attachmentID,
                patientId: patient.id,
                recordId: second.id,
                originalRelativePath: "\(firstPath)/original.pdf",
                displayFileName: "跨记录.pdf",
                kind: .pdf,
                pageIndex: 0,
                uniformTypeIdentifier: "com.adobe.pdf",
                byteCount: 8,
                sha256: String(repeating: "a", count: 64),
                importSource: .files
            )
        }
        #expect(throws: AttachmentValidationError.invalidRelativePath) {
            _ = try Attachment.verified(
                id: attachmentID,
                patientId: patient.id,
                recordId: second.id,
                originalRelativePath: "\(otherPatientPath)/original.pdf",
                displayFileName: "跨成员.pdf",
                kind: .pdf,
                pageIndex: 0,
                uniformTypeIdentifier: "com.adobe.pdf",
                byteCount: 8,
                sha256: String(repeating: "a", count: 64),
                importSource: .files
            )
        }
    }

    @Test("识别完成后追加另一成员页面会使旧 OCR 与分组代次全部失效")
    func appendAfterRecognition_requiresFreshTerminalOCRForEveryPage() throws {
        let controller = M3CaptureFlowController(
            patient: Patient(name: "妈妈", reportName: "王晓芸")
        )
        controller.loadAssets(
            [
                M3CapturePageAsset(
                    displayName: "第一页",
                    sourceOrder: 0,
                    captureSource: .photos
                )
            ],
            source: .photos
        )
        let firstGeneration = controller.flowGeneration
        controller.documents[0].pages[0].recognitionGeneration = firstGeneration
        controller.documents[0].pages[0].recognitionStatus = .recognized
        controller.markRecognitionCompleted()
        controller.hasAppliedGroupingSuggestions = true
        try controller.validateReadyForMaterialization()

        controller.appendAssets(
            [
                M3CapturePageAsset(
                    displayName: "另一成员页",
                    sourceOrder: 1,
                    detectedNames: [
                        DetectedNameCandidate(
                            name: "李明",
                            confidence: 0.99,
                            isReliable: true
                        )
                    ],
                    captureSource: .photos
                )
            ]
        )

        #expect(controller.flowGeneration == firstGeneration + 1)
        #expect(!controller.hasCompletedRecognition)
        #expect(!controller.hasAppliedGroupingSuggestions)
        #expect(controller.documents.flatMap(\.pages).allSatisfy {
            $0.recognitionGeneration == nil && $0.recognitionStatus == nil
        })
        #expect(throws: M3CaptureReadinessError.staleOrIncompleteRecognition) {
            try controller.validateReadyForMaterialization()
        }
    }

    @Test("旋转会失效旧识别且页级元数据可无损恢复来源方向和 PDF 页码")
    func rotation_invalidatesRecognitionAndMetadataRoundTrips() throws {
        let controller = M3CaptureFlowController(
            patient: Patient(name: "成员", reportName: "虚构姓名")
        )
        controller.loadAssets(
            [
                M3CapturePageAsset(
                    stagedAssetID: UUID(),
                    displayName: "PDF 第二页",
                    kind: .pdf,
                    sourceOrder: 0,
                    pdfPageIndex: 1,
                    captureSource: .files
                )
            ],
            source: .files
        )
        let generation = controller.flowGeneration
        controller.documents[0].pages[0].recognitionGeneration = generation
        controller.documents[0].pages[0].recognitionStatus = .noEvidence
        controller.markRecognitionCompleted()

        controller.rotate(documentIndex: 0, pageIndex: 0)

        let page = controller.documents[0].pages[0]
        #expect(page.rotationQuarterTurns == 1)
        #expect(page.recognitionGeneration == nil)
        #expect(page.recognitionStatus == nil)
        #expect(throws: M3CaptureReadinessError.staleOrIncompleteRecognition) {
            try controller.validateReadyForMaterialization()
        }

        var persistedPage = page
        persistedPage.recognitionGeneration = controller.flowGeneration
        persistedPage.recognitionStatus = .recognized
        let encoded = M3PersistedPageMetadata(
            page: persistedPage,
            flowGeneration: controller.flowGeneration
        ).encoded()
        let restored = try #require(M3PersistedPageMetadata.decode(encoded))
        #expect(restored.captureSource == .files)
        #expect(restored.rotationQuarterTurns == 1)
        #expect(restored.pdfPageIndex == 1)
        #expect(restored.flowGeneration == controller.flowGeneration)
        #expect(restored.recognitionGeneration == controller.flowGeneration)
        #expect(restored.recognitionStatus == .recognized)
    }

    @Test("混合来源按页面进入分组证据而不是继承批次来源")
    func mixedSources_preservePageLevelProvenance() {
        let pages = [
            M3CapturePageAsset(
                displayName: "相册页",
                sourceOrder: 0,
                captureSource: .photos
            ),
            M3CapturePageAsset(
                displayName: "PDF 页",
                kind: .pdf,
                sourceOrder: 1,
                pdfPageIndex: 0,
                captureSource: .files
            )
        ]

        let evidence = M3CaptureRecognitionPipeline.groupingEvidence(
            for: pages,
            source: .camera
        )

        #expect(evidence[0].source == .photoSelection)
        #expect(evidence[1].source == .multiPagePDF)
    }

    @Test("多姓名歧义不提供成员切换，只能重新分组或覆盖到冻结成员")
    func ambiguousNameGate_neverOffersMemberSwitch() {
        #expect(M3NameGatePresentationPolicy.canOfferMemberSwitch(for: .mismatch))
        #expect(!M3NameGatePresentationPolicy.canOfferMemberSwitch(for: .ambiguous))
        #expect(!M3NameGatePresentationPolicy.canOfferMemberSwitch(for: .match))
        #expect(!M3NameGatePresentationPolicy.canOfferMemberSwitch(for: .noEvidence))
    }

    @Test("旋转后的实际 OCR 预览交换像素轴，原始文件仍保持不变")
    func rotatedPreview_isUsedForOCRWithoutMutatingOriginal() async throws {
        let directory = try TestSupport.temporaryDirectory()
        let vault = try CaptureVaultService(
            rootURL: directory.appendingPathComponent("Vault")
        )
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 80, height: 40)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        let data = try #require(image.pngData())
        let staged = try vault.stagePhotoData(
            data,
            batchID: UUID(),
            displayName: "虚构方向样张.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let page = M3CapturePageAsset(
            stagedAssetID: staged.id,
            batchID: staged.batchID,
            displayName: staged.displayName,
            relativePath: staged.originalRelativePath,
            kind: .image,
            sourceOrder: 0,
            rotationQuarterTurns: 1,
            captureSource: .photos
        )

        let rendered = try await M3CaptureRecognitionPipeline.renderPreview(
            page: page,
            vault: vault
        )

        let decodedOriginal = try #require(UIImage(data: data))
        #expect(rendered.size.width == decodedOriginal.size.height)
        #expect(rendered.size.height == decodedOriginal.size.width)
        #expect(try Data(contentsOf: vault.url(for: staged.originalRelativePath)) == data)
    }

    @Test("分享原件只暴露受保护临时副本且字节哈希不变")
    func sharingOriginal_usesVerifiedTemporaryCopy() throws {
        let fixture = try makeFinalizationFixture()
        let finalized = try fixture.vault.finalize(
            asset: fixture.staged,
            patientID: fixture.patientID,
            recordID: fixture.recordID
        )
        let attachment = try Attachment.verified(
            id: fixture.staged.id,
            patientId: fixture.patientID,
            recordId: fixture.recordID,
            originalRelativePath: finalized.finalRelativePath,
            derivedRelativePath: finalized.finalPreviewRelativePath,
            displayFileName: "虚构分享报告.png",
            kind: .image,
            pageIndex: 0,
            uniformTypeIdentifier: fixture.staged.uniformTypeIdentifier,
            byteCount: fixture.staged.byteCount,
            sha256: fixture.staged.sha256,
            importSource: .photoLibrary
        )
        let shareRoot = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Share", isDirectory: true)
        let copy = try VaultShareCopyService(
            vault: fixture.vault,
            shareRootURL: shareRoot
        ).makeCopy(
            for: attachment,
            patientID: fixture.patientID,
            recordID: fixture.recordID
        )
        let original = try fixture.vault.url(
            for: finalized.finalRelativePath
        )

        #expect(copy != original)
        #expect(copy.path.hasPrefix(shareRoot.path + "/"))
        #expect(try Data(contentsOf: copy) == Data(contentsOf: original))
        #expect(
            try CaptureVaultService.sha256File(at: copy)
                == fixture.staged.sha256
        )
        #expect(try isExcluded(shareRoot))
        #expect(try isExcluded(copy))
    }

    @Test("分享原件拒绝跨成员或跨记录附件")
    func sharingOriginal_rejectsScopeMismatch() throws {
        let fixture = try makeFinalizationFixture()
        let finalized = try fixture.vault.finalize(
            asset: fixture.staged,
            patientID: fixture.patientID,
            recordID: fixture.recordID
        )
        let attachment = try Attachment.verified(
            id: fixture.staged.id,
            patientId: fixture.patientID,
            recordId: fixture.recordID,
            originalRelativePath: finalized.finalRelativePath,
            derivedRelativePath: finalized.finalPreviewRelativePath,
            displayFileName: "虚构分享报告.png",
            kind: .image,
            pageIndex: 0,
            uniformTypeIdentifier: fixture.staged.uniformTypeIdentifier,
            byteCount: fixture.staged.byteCount,
            sha256: fixture.staged.sha256,
            importSource: .photoLibrary
        )
        let service = VaultShareCopyService(
            vault: fixture.vault,
            shareRootURL: try TestSupport.temporaryDirectory()
        )

        #expect(throws: VaultShareCopyError.attachmentScopeMismatch) {
            try service.makeCopy(
                for: attachment,
                patientID: UUID(),
                recordID: fixture.recordID
            )
        }
    }

    @Test("分享前重新核验 Vault 原件大小和 SHA256")
    func sharingOriginal_rejectsIntegrityMismatch() throws {
        let fixture = try makeFinalizationFixture()
        let finalized = try fixture.vault.finalize(
            asset: fixture.staged,
            patientID: fixture.patientID,
            recordID: fixture.recordID
        )
        let attachment = try Attachment.verified(
            id: fixture.staged.id,
            patientId: fixture.patientID,
            recordId: fixture.recordID,
            originalRelativePath: finalized.finalRelativePath,
            derivedRelativePath: finalized.finalPreviewRelativePath,
            displayFileName: "虚构分享报告.png",
            kind: .image,
            pageIndex: 0,
            uniformTypeIdentifier: fixture.staged.uniformTypeIdentifier,
            byteCount: fixture.staged.byteCount,
            sha256: String(repeating: "b", count: 64),
            importSource: .photoLibrary
        )
        let service = VaultShareCopyService(
            vault: fixture.vault,
            shareRootURL: try TestSupport.temporaryDirectory()
        )

        #expect(throws: VaultShareCopyError.sourceIntegrityMismatch) {
            try service.makeCopy(
                for: attachment,
                patientID: fixture.patientID,
                recordID: fixture.recordID
            )
        }
    }

    private func isExcluded(_ url: URL) throws -> Bool {
        try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true
    }

    private func makeFinalizationFixture() throws -> (
        container: ModelContainer,
        vault: CaptureVaultService,
        staged: StagedCaptureAsset,
        patientID: UUID,
        recordID: UUID
    ) {
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        let vault = try CaptureVaultService(rootURL: root)
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 16, height: 16)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(
                CGRect(x: 0, y: 0, width: 16, height: 16)
            )
        }
        let batchID = UUID()
        return (
            try TestSupport.container(),
            vault,
            try vault.stagePhotoData(
                try #require(image.pngData()),
                batchID: batchID,
                displayName: "虚构事务报告.png",
                preferredExtension: "png",
                uniformTypeIdentifier: "public.png"
            ),
            UUID(),
            UUID()
        )
    }

    private func makeRecordFixture() throws -> (
        container: ModelContainer,
        context: ModelContext,
        patient: Patient,
        record: MedicalRecord,
        vault: CaptureVaultService
    ) {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "删除成员", reportName: "虚构姓名")
        let record = MedicalRecord(
            patientId: patient.id,
            title: "待删除报告",
            eventDate: Date()
        )
        context.insert(patient)
        context.insert(record)
        let root = try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
        return (
            container,
            context,
            patient,
            record,
            try CaptureVaultService(rootURL: root)
        )
    }

    private func createImmutableFiles(
        vault: CaptureVaultService,
        patientID: UUID,
        recordID: UUID,
        attachmentID: UUID
    ) throws -> (original: String, derived: String) {
        let base = "members/\(patientID.uuidString)/records/\(recordID.uuidString)/attachments/"
            + attachmentID.uuidString
        let original = "\(base)/original.pdf"
        let derived = "\(base)/preview.jpg"
        try writeImmutable(Data("original".utf8), to: vault.url(for: original))
        try writeImmutable(Data("preview".utf8), to: vault.url(for: derived))
        return (original, derived)
    }

    private func writeImmutable(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: url.path
        )
    }

    private func verifiedAttachment(
        id: UUID,
        patientID: UUID,
        recordID: UUID,
        original: String,
        derived: String
    ) throws -> Attachment {
        try Attachment.verified(
            id: id,
            patientId: patientID,
            recordId: recordID,
            originalRelativePath: original,
            derivedRelativePath: derived,
            displayFileName: "虚构报告.pdf",
            kind: .pdf,
            pageIndex: 0,
            uniformTypeIdentifier: "com.adobe.pdf",
            byteCount: 8,
            sha256: String(repeating: "a", count: 64),
            importSource: .files,
            pageCount: 2
        )
    }
}

private enum CaptureStagingFixtureError: Error {
    case injected
    case imageCreationFailed
}

private final class CaptureStagingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var observedMainThread = false

    func record(_ event: CaptureBulkStagingEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .started:
            observedMainThread = observedMainThread || Thread.isMainThread
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
        case .finished:
            inFlight -= 1
        }
    }
}

private final class CaptureExpectedHashStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: String] = [:]

    func set(_ value: String, for index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func value(for index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[index]
    }
}

private func makeDeterministicHighEntropyJPEG(
    width: Int,
    height: Int,
    seed: UInt64
) throws -> Data {
    var state = seed
    let byteCount = width * height * 4
    var pixels = Data(count: byteCount)
    pixels.withUnsafeMutableBytes { rawBuffer in
        guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            return
        }
        for offset in stride(from: 0, to: byteCount, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            bytes[offset] = UInt8(truncatingIfNeeded: state >> 24)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 32)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 40)
            bytes[offset + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: pixels as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(
                  rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ) else {
        throw CaptureStagingFixtureError.imageCreationFailed
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw CaptureStagingFixtureError.imageCreationFailed
    }
    CGImageDestinationAddImage(
        destination,
        image,
        [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw CaptureStagingFixtureError.imageCreationFailed
    }
    return output as Data
}
