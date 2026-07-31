import Foundation
import Testing
import UIKit
@testable import CareThread

/// Regression coverage migrated from the retired duplicate Vault layer.
///
/// `CaptureVaultService` is the single authority for protected originals,
/// staging journals, final member paths, integrity checks, and deletion.
@MainActor
struct CaptureVaultSafetyContractTests {
    @Test("有效图片只暂存一份原件并可原子移入成员目录")
    func validImage_stagesOnceAndFinalizesIntoMemberVault() throws {
        let root = try makeRoot()
        let vault = try CaptureVaultService(rootURL: root)
        let data = try makePNG()
        let staged = try vault.stagePhotoData(
            data,
            batchID: UUID(),
            displayName: "虚构报告.png",
            preferredExtension: "PNG",
            uniformTypeIdentifier: "public.png"
        )

        #expect(try Data(contentsOf: vault.url(for: staged.originalRelativePath)) == data)
        let final = try vault.finalize(
            asset: staged,
            patientID: UUID(),
            recordID: UUID()
        )
        #expect(!FileManager.default.fileExists(
            atPath: try vault.url(for: staged.originalRelativePath).path
        ))
        #expect(try Data(contentsOf: vault.url(for: final.finalRelativePath)) == data)
    }

    @Test("已完成的原件不能用同一暂存资产再次覆盖")
    func finalizedAsset_cannotOverwriteExistingOriginal() throws {
        let root = try makeRoot()
        let vault = try CaptureVaultService(rootURL: root)
        let staged = try vault.stagePhotoData(
            try makePNG(),
            batchID: UUID(),
            displayName: "虚构报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        let patientID = UUID()
        let recordID = UUID()
        let final = try vault.finalize(
            asset: staged,
            patientID: patientID,
            recordID: recordID
        )
        let bytes = try Data(contentsOf: vault.url(for: final.finalRelativePath))

        #expect(throws: CaptureVaultError.invalidBatch) {
            _ = try vault.finalize(
                asset: staged,
                patientID: patientID,
                recordID: recordID
            )
        }
        #expect(try Data(contentsOf: vault.url(for: final.finalRelativePath)) == bytes)
    }

    @Test("不支持的扩展名直接拒绝")
    func unsupportedExtension_isRejected() throws {
        let vault = try CaptureVaultService(rootURL: makeRoot())
        #expect(throws: CaptureVaultError.unsupportedType) {
            _ = try vault.stagePhotoData(
                try makePNG(),
                batchID: UUID(),
                displayName: "虚构报告.exe",
                preferredExtension: "exe",
                uniformTypeIdentifier: "public.png"
            )
        }
    }

    @Test("绝对路径解析被拒绝")
    func absolutePath_isRejected() throws {
        let vault = try CaptureVaultService(rootURL: makeRoot())
        #expect(throws: CaptureVaultError.invalidRelativePath) {
            _ = try vault.url(for: "/tmp/private")
        }
    }

    @Test("父目录穿越解析被拒绝")
    func pathTraversal_isRejected() throws {
        let vault = try CaptureVaultService(rootURL: makeRoot())
        #expect(throws: CaptureVaultError.invalidRelativePath) {
            _ = try vault.url(for: "members/../../secret")
        }
    }

    @Test("暂存原件丢失时给出明确错误且不生成最终文件")
    func missingStagedOriginal_isRejected() throws {
        let vault = try CaptureVaultService(rootURL: makeRoot())
        let staged = try vault.stagePhotoData(
            try makePNG(),
            batchID: UUID(),
            displayName: "虚构报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )
        try FileManager.default.removeItem(
            at: vault.url(for: staged.originalRelativePath)
        )

        #expect(throws: CaptureVaultError.sourceMissing) {
            _ = try vault.finalize(
                asset: staged,
                patientID: UUID(),
                recordID: UUID()
            )
        }
    }

    @Test("附件清理同时删除原件与派生预览")
    func attachmentCleanup_removesOriginalAndPreview() throws {
        let root = try makeRoot()
        let vault = try CaptureVaultService(rootURL: root)
        let original = "members/member/records/record/attachments/item/original.png"
        let preview = "members/member/records/record/attachments/item/preview.jpg"
        for path in [original, preview] {
            let url = try vault.url(for: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(path.utf8).write(to: url)
        }

        vault.deleteAttachmentFiles(
            derivedRelativePaths: [preview],
            unreferencedOriginalRelativePaths: [original]
        )

        #expect(!FileManager.default.fileExists(atPath: try vault.url(for: original).path))
        #expect(!FileManager.default.fileExists(atPath: try vault.url(for: preview).path))
    }

    @Test("丢弃未提交批次会清理全部暂存文件")
    func uncommittedBatchDiscard_removesStagingDirectory() throws {
        let root = try makeRoot()
        let vault = try CaptureVaultService(rootURL: root)
        let batchID = UUID()
        _ = try vault.stagePhotoData(
            try makePNG(),
            batchID: batchID,
            displayName: "虚构报告.png",
            preferredExtension: "png",
            uniformTypeIdentifier: "public.png"
        )

        try vault.discardBatch(batchID)

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("staging/\(batchID.uuidString)").path
        ))
    }

    @Test("空 Vault 批次可安全创建并丢弃")
    func emptyBatch_canBeDiscardedWithoutResidue() throws {
        let root = try makeRoot()
        let vault = try CaptureVaultService(rootURL: root)
        let batchID = UUID()
        try vault.beginBatch(batchID)

        try vault.discardBatch(batchID)

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("staging/\(batchID.uuidString)").path
        ))
    }

    @Test("最终文件孤儿扫描只返回未被数据库引用的文件")
    func finalizedOrphanScan_returnsOnlyUnreferencedFiles() throws {
        let root = try makeRoot()
        let vault = try CaptureVaultService(rootURL: root)
        let referenced = "members/member/records/record/attachments/one/original.png"
        let orphan = "members/member/records/record/attachments/two/original.png"
        for path in [referenced, orphan] {
            let url = try vault.url(for: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(path.utf8).write(to: url)
        }

        #expect(
            try vault.orphanFinalizedAttachmentRelativePaths(
                referencedPaths: [referenced]
            ) == [orphan]
        )
    }

    @Test("空成员 Vault 的最终文件孤儿扫描返回空数组")
    func finalizedOrphanScan_whenVaultEmpty_returnsEmpty() throws {
        let vault = try CaptureVaultService(rootURL: makeRoot())
        #expect(
            try vault.orphanFinalizedAttachmentRelativePaths(
                referencedPaths: []
            ).isEmpty
        )
    }

    private func makeRoot() throws -> URL {
        try TestSupport.temporaryDirectory()
            .appendingPathComponent("Vault", isDirectory: true)
    }

    private func makePNG() throws -> Data {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 24, height: 24)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return try #require(image.pngData())
    }
}
