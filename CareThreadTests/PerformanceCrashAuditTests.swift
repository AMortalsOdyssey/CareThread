import CryptoKit
import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import CareThread

@Suite("Performance, memory-proxy, and crash-recovery audit", .serialized)
struct PerformanceCrashAuditTests {
    @MainActor
    @Test("300 条组合筛选 seek 分页与 100 次成员切换稳定有界")
    func threeHundredRecords_combinedFiltersAndOneHundredSwitches() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let first = Patient(name: "虚构压测成员甲")
        let second = Patient(name: "虚构压测成员乙")
        context.insert(first)
        context.insert(second)
        let base = CTDate.make(2025, 1, 1)
        var expected: [UUID: Set<UUID>] = [first.id: [], second.id: []]

        for (memberIndex, patient) in [first, second].enumerated() {
            for index in 0..<300 {
                let matches = index.isMultiple(of: 3)
                let record = MedicalRecord(
                    patientId: patient.id,
                    type: matches ? .lab : .outpatient,
                    title: matches
                        ? "虚构血糖趋势-\(index % 11)"
                        : "虚构其他记录-\(index)",
                    summary: "完全虚构的本地性能样本 \(memberIndex)-\(index)",
                    eventDate: base.addingTimeInterval(TimeInterval(index * 3_600)),
                    hospital: matches ? "虚构中心医院" : "虚构其他医院",
                    doctor: matches ? "虚构医生" : "虚构其他医生",
                    primaryDisease: matches ? "虚构代谢情况" : "虚构其他情况",
                    diseaseTags: matches ? ["长期随访"] : [],
                    ageAtEvent: matches ? 65 : 30,
                    createdAt: base.addingTimeInterval(TimeInterval(index))
                )
                context.insert(record)
                if matches {
                    expected[patient.id, default: []].insert(record.id)
                }
            }
        }
        try context.save()

        var filter = M3RecordFilter()
        filter.startDate = base
        filter.endDate = base.addingTimeInterval(300 * 3_600)
        filter.typeRawValues = [RecordType.lab.rawValue]
        filter.diseaseValues = ["虚构代谢情况"]
        filter.hospitalValues = ["虚构中心医院"]
        filter.doctorValues = ["虚构医生"]
        filter.minimumAge = 60
        filter.maximumAge = 70
        filter.sort = .title

        let started = CFAbsoluteTimeGetCurrent()
        var maximumPageCount = 0
        for cycle in 0..<100 {
            let patient = cycle.isMultiple(of: 2) ? first : second
            var cursor: M3RecordCursor?
            var observed = Set<UUID>()
            var pageCount = 0
            repeat {
                let page = try M3RecordLibraryService.page(
                    context: context,
                    patientID: patient.id,
                    searchText: "血糖",
                    filter: filter,
                    generation: cycle,
                    after: cursor
                )
                pageCount += 1
                #expect(page.records.count <= M3RecordLibraryService.pageSize)
                #expect(Set(page.records.map(\.patientId)) == [patient.id])
                for record in page.records {
                    #expect(observed.insert(record.id).inserted)
                }
                cursor = page.nextCursor
            } while cursor != nil
            maximumPageCount = max(maximumPageCount, pageCount)
            #expect(observed == expected[patient.id])
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        printMetric(
            "record_filter_300x2_switch_100",
            seconds: elapsed,
            details: "max_pages=\(maximumPageCount), page_size=\(M3RecordLibraryService.pageSize)"
        )
        #expect(elapsed < 30)
    }

    @Test("100 页批次、50 页文档与 22 页提示路径连续 100 轮无退化")
    @MainActor
    func importGrouping_limitsRemainLinearAcrossOneHundredCycles() throws {
        let engine = ImportGroupingEngine()
        let batch = makeGroupingPages(
            count: 100,
            source: .photoSelection,
            sessionPrefix: "batch"
        )
        let document = makeGroupingPages(
            count: 50,
            source: .multiPagePDF,
            sessionPrefix: "one-document",
            sharedSession: true
        )
        let member = Patient(name: "虚构长报告成员")
        let controller = M3CaptureFlowController(patient: member)
        controller.documents = [
            M3CaptureDocument(
                pages: (0..<22).map {
                    M3CapturePageAsset(
                        displayName: "虚构长报告第 \($0 + 1) 页",
                        sourceOrder: $0
                    )
                }
            )
        ]

        let started = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            let batchResult = try engine.suggest(pages: batch)
            #expect(batchResult.orderedPageIDs.count == 100)
            let documentResult = try engine.suggest(pages: document)
            #expect(documentResult.groups.count == 1)
            #expect(documentResult.groups[0].pageIDs.count == 50)
            controller.markGroupingConfirmed()
            #expect(!controller.groupingConfirmed)
            #expect(controller.errorMessage == Copy.Capture.largeDocumentWarning)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        printMetric(
            "import_grouping_100_50_22_cycles_100",
            seconds: elapsed,
            details: "evaluated_pages=17200"
        )
        #expect(elapsed < 15)
    }

    @MainActor
    @Test("真实 48MP 合成 JPEG 生成 3000px 工作图且原件 SHA256 不变")
    func fortyEightMegapixel_originalHashAndWorkingImage() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceData = try syntheticJPEG(width: 8_000, height: 6_000)
        let originalHash = CaptureVaultService.sha256(sourceData)
        let vault = try CaptureVaultService(
            rootURL: root.appendingPathComponent("Vault", isDirectory: true)
        )
        let batchID = deterministicUUID(90_001)

        let started = CFAbsoluteTimeGetCurrent()
        let staged = try autoreleasepool {
            try vault.stagePhotoData(
                sourceData,
                batchID: batchID,
                displayName: "完全虚构的 48MP 压测图.jpg"
            )
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let originalURL = try vault.url(for: staged.originalRelativePath)
        let previewURL = try vault.url(
            for: try #require(staged.previewRelativePath)
        )
        let previewSource = try #require(
            CGImageSourceCreateWithURL(previewURL as CFURL, nil)
        )
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(previewSource, 0, nil)
                as? [CFString: Any]
        )
        let previewWidth = try #require(
            properties[kCGImagePropertyPixelWidth] as? Int
        )
        let previewHeight = try #require(
            properties[kCGImagePropertyPixelHeight] as? Int
        )

        #expect(staged.pixelWidth == 8_000)
        #expect(staged.pixelHeight == 6_000)
        #expect(previewWidth == 3_000)
        #expect(previewHeight == 2_250)
        #expect(try CaptureVaultService.sha256File(at: originalURL) == originalHash)
        #expect(
            try originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == sourceData.count
        )
        printMetric(
            "capture_48mp_downsample",
            seconds: elapsed,
            details:
                "source_bytes=\(sourceData.count), preview=\(previewWidth)x\(previewHeight), hash_chunk=\(CaptureVaultService.streamingChunkBytes)"
        )
        #expect(elapsed < 20)
    }

    @Test("250MiB 稀疏 PDF 以文件流暂存并保持长度与 SHA256")
    func sparseTwoHundredFiftyMiBPDFStagesWithoutWholeFileData() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("fictional-250mib.pdf")
        let streamLength = 250 * 1_024 * 1_024
        try makeSparsePDF(at: sourceURL, streamLength: streamLength)
        let sourceSize = try #require(
            sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        #expect(sourceSize >= streamLength)
        let sourceSHA256 = try CaptureVaultService.sha256File(at: sourceURL)
        let vault = try CaptureVaultService(
            rootURL: root.appendingPathComponent("Vault", isDirectory: true)
        )

        let started = CFAbsoluteTimeGetCurrent()
        let staged = try vault.stageFile(
            at: sourceURL,
            batchID: deterministicUUID(90_101),
            displayName: "完全虚构的 250MiB 稀疏报告.pdf"
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let stagedURL = try vault.url(for: staged.originalRelativePath)
        let stagedSize = try #require(
            stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        #expect(staged.kind == .pdf)
        #expect(staged.pageCount == 1)
        #expect(staged.byteCount == Int64(sourceSize))
        #expect(stagedSize == sourceSize)
        #expect(staged.sha256 == sourceSHA256)
        printMetric(
            "vault_stage_sparse_pdf_250mib",
            seconds: elapsed,
            details:
                "bytes=\(sourceSize), hash_chunk=\(CaptureVaultService.streamingChunkBytes)"
        )
        #expect(elapsed < 60)
    }

    @Test("16MiB Nearby 文件逐块加密接收且取消清理无残留")
    func nearbySixteenMiBStreamingAndCleanup() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("fictional-source.bin")
        let sourceByteCount = 16 * 1_024 * 1_024
        let sourceSHA256: String = try autoreleasepool {
            let data = Data(repeating: 0xA7, count: sourceByteCount)
            try data.write(to: sourceURL, options: .atomic)
            return Data(SHA256.hash(data: data)).auditHex
        }
        let transferID = deterministicUUID(91_001)
        let patientID = deterministicUUID(91_002)
        let fileID = deterministicUUID(91_003)
        let descriptor = try TransferFileDescriptor(
            kind: .originalAttachment,
            fileID: fileID,
            patientID: patientID,
            ownerAttachmentID: deterministicUUID(91_004),
            relativePath: "members/\(patientID.uuidString.lowercased())/original.bin",
            byteCount: Int64(sourceByteCount),
            sha256: sourceSHA256
        ).validated()
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let store = try TransferStagingStore(
            rootURL: stagingRoot,
            minimumFreeSpaceBytes: 0
        )
        let reader = try TransferFileChunkReader(
            fileURL: sourceURL,
            descriptor: descriptor,
            transferID: transferID,
            key: key
        )
        let receiver = try await TransferFileChunkReceiver.make(
            stagingStore: store,
            descriptor: descriptor,
            transferID: transferID,
            key: key
        )

        let started = CFAbsoluteTimeGetCurrent()
        var chunkCount = 0
        var maximumFrameBytes = 0
        while let frame = try await reader.nextFrame() {
            let wire = try TransferChunkWireCodec.encode(frame)
            maximumFrameBytes = max(maximumFrameBytes, wire.count)
            _ = try await receiver.accept(
                TransferChunkWireCodec.decode(wire)
            )
            chunkCount += 1
        }
        try await receiver.finalize()
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        #expect(chunkCount == sourceByteCount / TransferLimits.chunkSize)
        #expect(maximumFrameBytes <= TransferChunkWireCodec.maximumEncodedBytes)
        let verifiedURL = try await store.verifiedFileURL(
            transferID: transferID,
            descriptor: descriptor
        )
        #expect(try TransferFileHashing.sha256(url: verifiedURL) == descriptor.sha256)

        try await store.cleanup(transferID: transferID)
        let transferDirectory = stagingRoot.appendingPathComponent(
            transferID.uuidString.lowercased(),
            isDirectory: true
        )
        #expect(!FileManager.default.fileExists(atPath: transferDirectory.path))
        printMetric(
            "nearby_stream_16mib",
            seconds: elapsed,
            details:
                "chunks=\(chunkCount), max_frame=\(maximumFrameBytes), resident_plaintext_proxy=\(TransferLimits.chunkSize)"
        )
        #expect(elapsed < 30)
    }

    @Test("8MiB 备份以 1MiB AEAD 分块加解密且字节完全一致")
    func backupEightMiBChunkedEncryptionRoundTrip() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fictional-readable.zip")
        let encrypted = root.appendingPathComponent("fictional.ctbackup")
        let restored = root.appendingPathComponent("fictional-restored.zip")
        let sourceByteCount = 8 * 1_024 * 1_024
        try autoreleasepool {
            try Data(repeating: 0x5C, count: sourceByteCount)
                .write(to: source, options: .atomic)
        }
        let expectedHash = try BackupExporter.sha256(source)

        let started = CFAbsoluteTimeGetCurrent()
        try BackupEncryption.encrypt(
            zipURL: source,
            password: "Fictional-Performance-Only!",
            outputURL: encrypted,
            randomBytes: { count in
                Data(repeating: UInt8(count), count: count)
            }
        )
        try BackupEncryption.decrypt(
            encryptedURL: encrypted,
            password: "Fictional-Performance-Only!",
            outputZipURL: restored
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        #expect(BackupEncryption.chunkSize == 1 * 1_024 * 1_024)
        #expect(try BackupExporter.sha256(restored) == expectedHash)
        #expect(
            try restored.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == sourceByteCount
        )
        printMetric(
            "backup_aead_stream_8mib",
            seconds: elapsed,
            details:
                "chunk_bytes=\(BackupEncryption.chunkSize), plaintext_buffers_proxy=\(BackupEncryption.chunkSize * 2)"
        )
        #expect(elapsed < 45)
    }

    @Test("300 条记录 PDF 逐页生成并显式删除临时副本")
    func pdfThreeHundredRecordsIsBoundedAndCleaned() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let memberID = deterministicUUID(99_001)
        var records: [BriefRecordSnapshot] = []
        records.reserveCapacity(300)
        for index in 0..<300 {
            records.append(
                makePDFRecord(index: index, memberID: memberID)
            )
        }
        let input = BriefInput(
            member: BriefMemberSnapshot(
                id: memberID,
                displayName: "虚构长期成员",
                birthDate: CTDate.make(1980, 1, 1),
                conditions: ["虚构长期随访"],
                allergies: [],
                histories: []
            ),
            records: records,
            medications: [],
            followUps: []
        )
        let payload = BriefBuilder.exportPayload(
            input: input,
            preset: .all,
            generatedAt: CTDate.make(2026, 7, 31)
        )
        let store = M7TemporaryExportStore(
            rootURL: root.appendingPathComponent("pdf", isDirectory: true)
        )

        let started = CFAbsoluteTimeGetCurrent()
        let result = try await M7PDFExportService(store: store)
            .exportAsync(payload)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        #expect(payload.records.count == 300)
        #expect(result.pageCount >= 20)
        #expect(result.byteCount > 4_096)
        #expect(!result.renderedOnMainThread)
        store.remove(result.fileURL)
        #expect(!FileManager.default.fileExists(atPath: result.fileURL.path))
        printMetric(
            "pdf_export_records_300",
            seconds: elapsed,
            details: "pages=\(result.pageCount), bytes=\(result.byteCount)"
        )
        #expect(elapsed < 30)
    }

    @MainActor
    @Test("备份导出包与导入预检工作区 100 次丢弃后零残留")
    func backupTemporaryArtifacts_oneHundredCyclesLeaveNoResidue() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = BackupPreview(
            backupID: deterministicUUID(92_001),
            exportedAt: CTDate.make(2026, 7, 31),
            memberNames: ["虚构成员"],
            memberCount: 1,
            recordCount: 0,
            attachmentCount: 0,
            totalByteCount: 0
        )
        let manifest = BackupManifest(
            backupID: deterministicUUID(92_002),
            exportedAt: CTDate.make(2026, 7, 31),
            scope: .allMembers,
            memberNames: ["虚构成员"],
            entityCounts: ["patients": 1],
            files: []
        )
        let payload = BackupPortablePayloadV1(
            schemaVersion: 1,
            entities: [],
            importBatches: [],
            captureDrafts: [],
            capturePages: [],
            appleReminderBindings: [],
            contentRevisions: []
        )

        for cycle in 0..<100 {
            let exportContainer = root.appendingPathComponent(
                deterministicUUID(93_000 + cycle).uuidString.lowercased(),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: exportContainer,
                withIntermediateDirectories: true
            )
            let archive = exportContainer.appendingPathComponent("backup.ctbackup")
            try Data("虚构备份".utf8).write(to: archive)
            BackupExportPackage(archiveURL: archive, preview: preview).discard()
            #expect(!FileManager.default.fileExists(atPath: exportContainer.path))

            let importContainer = root.appendingPathComponent(
                deterministicUUID(94_000 + cycle).uuidString.lowercased(),
                isDirectory: true
            )
            let stagedRoot = importContainer.appendingPathComponent(
                "content/CareThread-Backup",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: stagedRoot,
                withIntermediateDirectories: true
            )
            BackupImportPlan(
                manifest: manifest,
                preview: preview,
                stagingContainerURL: importContainer,
                stagedRootURL: stagedRoot,
                portablePayload: payload
            ).discard()
            #expect(!FileManager.default.fileExists(atPath: importContainer.path))
        }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(remaining.isEmpty)
    }

    @Test("100 次 staging 建立与取消只删除目标传输且 actor 状态归零")
    func stagingCancellation_oneHundredCyclesIsScopedAndStable() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let store = try TransferStagingStore(
            rootURL: staging,
            quotaBytes: 32 * 1_024 * 1_024,
            minimumFreeSpaceBytes: 0
        )
        let patientID = deterministicUUID(95_001)
        let started = CFAbsoluteTimeGetCurrent()
        for cycle in 0..<100 {
            let transferID = deterministicUUID(96_000 + cycle)
            let fileID = deterministicUUID(97_000 + cycle)
            let descriptor = try TransferFileDescriptor(
                kind: .originalAttachment,
                fileID: fileID,
                patientID: patientID,
                ownerAttachmentID: deterministicUUID(98_000 + cycle),
                relativePath: "members/\(patientID.uuidString.lowercased())/\(cycle).bin",
                byteCount: 1_024,
                sha256: String(repeating: "a", count: 64)
            ).validated()
            _ = try await store.prepare(
                transferID: transferID,
                descriptor: descriptor,
                resume: nil
            )
            try await store.cleanup(transferID: transferID)
            #expect(await store.recoveryStatuses().isEmpty)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let residual = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        #expect(residual.isEmpty)
        printMetric(
            "staging_prepare_cancel_100",
            seconds: elapsed,
            details: "residual_entries=\(residual.count)"
        )
        #expect(elapsed < 15)
    }

    private func makeGroupingPages(
        count: Int,
        source: ImportPageSource,
        sessionPrefix: String,
        sharedSession: Bool = false
    ) -> [ImportPageEvidence] {
        (0..<count).map { index in
            ImportPageEvidence(
                pageID: deterministicUUID(10_000 + index),
                sourceOrder: index,
                sourceSessionID: sharedSession
                    ? sessionPrefix
                    : "\(sessionPrefix)-\(index)",
                source: source,
                reportNumber: sharedSession ? "FICT-001" : nil,
                pageNumber: sharedSession ? index + 1 : nil,
                totalPages: sharedSession ? count : nil,
                topOCRLines: ["虚构报告页 \(index + 1)"],
                bottomOCRLines: ["虚构报告页 \(index + 1)"]
            )
        }
    }

    private func syntheticJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = try #require(
            CGColorSpace(name: CGColorSpace.sRGB)
        )
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(
            UIColor(red: 0.91, green: 0.94, blue: 0.97, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 500, y: 500, width: 2_000, height: 120))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Builds a valid one-page PDF whose content stream is a filesystem hole.
    /// Only the small object table and trailer are materialized in memory.
    private func makeSparsePDF(
        at url: URL,
        streamLength: Int
    ) throws {
        guard streamLength > 0 else {
            throw CaptureVaultError.invalidImage
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var objectOffsets: [UInt64] = []

        try handle.write(contentsOf: Data("%PDF-1.4\n".utf8))
        objectOffsets.append(try handle.offset())
        try handle.write(
            contentsOf: Data(
                "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".utf8
            )
        )
        objectOffsets.append(try handle.offset())
        try handle.write(
            contentsOf: Data(
                "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
                    .utf8
            )
        )
        objectOffsets.append(try handle.offset())
        try handle.write(
            contentsOf: Data(
                "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>\nendobj\n"
                    .utf8
            )
        )
        objectOffsets.append(try handle.offset())
        try handle.write(
            contentsOf: Data(
                "4 0 obj\n<< /Length \(streamLength) >>\nstream\n".utf8
            )
        )
        let streamStart = try handle.offset()
        try handle.seek(toOffset: streamStart + UInt64(streamLength))
        try handle.write(contentsOf: Data("\nendstream\nendobj\n".utf8))
        let xrefOffset = try handle.offset()
        var xref = "xref\n0 5\n0000000000 65535 f \n"
        for offset in objectOffsets {
            xref += String(format: "%010llu 00000 n \n", offset)
        }
        xref += """
        trailer
        << /Size 5 /Root 1 0 R >>
        startxref
        \(xrefOffset)
        %%EOF

        """
        try handle.write(contentsOf: Data(xref.utf8))
        try handle.synchronize()
    }

    private func makePDFRecord(
        index: Int,
        memberID: UUID
    ) -> BriefRecordSnapshot {
        let eventDate = CTDate.make(
            2026 - index / 120,
            (index % 12) + 1,
            (index % 28) + 1
        )
        let recordTypeIndex = index % RecordType.allCases.count
        let isAbnormal = index.isMultiple(of: 13)
        let abnormalFlags = isAbnormal ? ["虚构异常标记"] : []
        let field = KeyValueItem(
            key: "虚构字段",
            value: "值 \(index)"
        )
        let measurement = BriefMeasurementSnapshot(
            name: "虚构指标",
            numericValue: Double(index) / 10,
            textualValue: nil,
            unit: "u",
            abnormalState: isAbnormal ? .high : .none
        )
        return BriefRecordSnapshot(
            id: deterministicUUID(100_000 + index),
            patientID: memberID,
            eventDate: eventDate,
            title: "虚构长期记录 \(index + 1)",
            summary: "完全虚构的长期病程整理文本，仅用于 PDF 性能与分页验证。",
            type: RecordType.allCases[recordTypeIndex],
            reviewStatus: .confirmed,
            isInBrief: index < 20,
            abnormalFlags: abnormalFlags,
            structuredFields: [field],
            measurements: [measurement],
            tags: []
        )
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "F0F00000-0000-0000-0000-%012d",
                value
            )
        )!
    }

    private func printMetric(
        _ name: String,
        seconds: TimeInterval,
        details: String
    ) {
        print(
            String(
                format: "PERF_METRIC %@ elapsed_ms=%.2f %@",
                name,
                seconds * 1_000,
                details
            )
        )
    }
}

private extension Data {
    var auditHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
