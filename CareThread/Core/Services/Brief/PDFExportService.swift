import Foundation
import UIKit

enum M7PDFExportError: Error, Equatable {
    case emptyDocument
    case recordLimitExceeded
    case outputTooSmall
}

struct M7PDFExportResult: Equatable, Sendable {
    let fileURL: URL
    let byteCount: Int64
    let pageCount: Int
    let renderedOnMainThread: Bool
}

struct M7TemporaryExportStore {
    static let requiredFileProtection = FileProtectionType.complete

    let fileManager: FileManager
    let rootURL: URL

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "CareThreadProtectedExports",
                isDirectory: true
            )
    }

    func preparePDFURL() throws -> URL {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.requiredFileProtection]
        )
        try fileManager.setAttributes(
            [.protectionKey: Self.requiredFileProtection],
            ofItemAtPath: rootURL.path
        )
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try mutableRoot.setResourceValues(directoryValues)
        return rootURL.appendingPathComponent(
            "CareThread-summary-\(UUID().uuidString).pdf",
            isDirectory: false
        )
    }

    func protect(_ fileURL: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: Self.requiredFileProtection],
            ofItemAtPath: fileURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
    }

    func remove(_ fileURL: URL) {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
                AppLog.vault.info("Protected brief share copy removed")
            }
        } catch {
            AppLog.vault.error(
                "Failed to remove protected brief share copy: \(error.localizedDescription)"
            )
        }
    }
}

struct M7PDFExportService {
    let store: M7TemporaryExportStore
    let shouldCancel: @Sendable () -> Bool

    init(
        store: M7TemporaryExportStore = M7TemporaryExportStore(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.store = store
        self.shouldCancel = shouldCancel
    }

    /// Runs all UIKit PDF drawing and filesystem work away from the main
    /// actor. Cancellation after rendering removes the protected temporary
    /// file before propagating `CancellationError`.
    func exportAsync(
        _ payload: RecordExportPayload
    ) async throws -> M7PDFExportResult {
        let rootURL = store.rootURL
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let backgroundStore = M7TemporaryExportStore(rootURL: rootURL)
            let result = try M7PDFExportService(
                store: backgroundStore,
                shouldCancel: { Task.isCancelled }
            ).export(payload)
            guard !Task.isCancelled else {
                backgroundStore.remove(result.fileURL)
                throw CancellationError()
            }
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            guard !Task.isCancelled else {
                M7TemporaryExportStore(rootURL: rootURL)
                    .remove(result.fileURL)
                throw CancellationError()
            }
            return result
        } onCancel: {
            task.cancel()
        }
    }

    func export(_ payload: RecordExportPayload) throws -> M7PDFExportResult {
        guard payload.brief.hasExportableContent || !payload.records.isEmpty else {
            AppLog.userAction.warning(
                "PDF export rejected because the brief is empty"
            )
            throw M7PDFExportError.emptyDocument
        }
        guard payload.records.count <= M7BriefDataLoader.maximumExportRecordCount
        else {
            AppLog.userAction.warning(
                "PDF export rejected because the record cap was exceeded"
            )
            throw M7PDFExportError.recordLimitExceeded
        }
        guard !shouldCancel() else { throw CancellationError() }
        let url = try store.preparePDFURL()
        do {
            let renderer = M7PDFRenderer(
                payload: payload,
                shouldCancel: shouldCancel
            )
            let pageCount = try renderer.write(to: url)
            try store.protect(url)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount > 4_096 else {
                store.remove(url)
                throw M7PDFExportError.outputTooSmall
            }
            AppLog.userAction.info(
                "Protected local PDF export completed: \(pageCount) pages, \(byteCount) bytes"
            )
            return M7PDFExportResult(
                fileURL: url,
                byteCount: byteCount,
                pageCount: pageCount,
                renderedOnMainThread: Thread.isMainThread
            )
        } catch {
            store.remove(url)
            AppLog.vault.error(
                "Local PDF export failed: \(error.localizedDescription)"
            )
            throw error
        }
    }
}

private final class M7PDFRenderer {
    private enum Layout {
        static let pointsPerMillimeter: CGFloat = 72 / 25.4
        static let page = CGRect(
            x: 0,
            y: 0,
            width: 210 * pointsPerMillimeter,
            height: 297 * pointsPerMillimeter
        )
        static let margin = 18 * pointsPerMillimeter
        static let contentWidth = page.width - margin * 2
        static let headerHeight: CGFloat = 50
        static let footerHeight: CGFloat = 32
        static let sectionSpacing: CGFloat = 12
        static let itemSpacing: CGFloat = 5
        static let bodyLineHeight: CGFloat = 19.5
    }

    private let payload: RecordExportPayload
    private let shouldCancel: @Sendable () -> Bool
    private let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
    private let sectionFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    private let bodyFont = UIFont.systemFont(ofSize: 13, weight: .regular)
    private let bodyStrongFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    private let headerFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
    private let footerFont = UIFont.systemFont(ofSize: 9, weight: .regular)
    private let payloadDateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()

    private var pageNumber = 0
    private var cursorY: CGFloat = 0
    private var context: UIGraphicsPDFRendererContext?
    private var wasCancelled = false

    init(
        payload: RecordExportPayload,
        shouldCancel: @escaping @Sendable () -> Bool
    ) {
        self.payload = payload
        self.shouldCancel = shouldCancel
    }

    func write(to url: URL) throws -> Int {
        guard !stopIfCancelled() else { throw CancellationError() }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String:
                "CareThread 就诊摘要 - \(payload.memberName)",
            kCGPDFContextCreator as String: "CareThread",
            kCGPDFContextAuthor as String: payload.memberName,
            kCGPDFContextSubject as String:
                "本地整理的就诊沟通资料，不提供诊断"
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: Layout.page,
            format: format
        )
        try renderer.writePDF(to: url) { rendererContext in
            guard !stopIfCancelled() else { return }
            context = rendererContext
            defer { context = nil }
            beginPage()
            guard !stopIfCancelled() else { return }
            drawTitle()
            guard !stopIfCancelled() else { return }
            drawBrief()
            guard !stopIfCancelled() else { return }
            drawRecordAppendix()
            guard !stopIfCancelled() else { return }
            drawSources()
            guard !stopIfCancelled() else { return }
            drawBrandClosingBlock()
            if !stopIfCancelled() {
                finishPage()
            }
        }
        guard !wasCancelled else { throw CancellationError() }
        return pageNumber
    }

    private func beginPage() {
        context?.beginPage()
        pageNumber += 1
        CareThreadPDFBranding.drawHeader(
            in: CGRect(
                x: Layout.margin,
                y: Layout.margin,
                width: Layout.contentWidth,
                height: CareThreadPDFBranding.headerHeight
            )
        )
        let header = "CareThread 就诊摘要 · \(payload.memberName) · 生成于 \(payloadDateFormatter.string(from: payload.generatedAt))"
        draw(
            header,
            at: CGPoint(
                x: Layout.margin,
                y: Layout.margin + CareThreadPDFBranding.headerHeight
            ),
            width: Layout.contentWidth,
            font: headerFont,
            color: .darkGray,
            lineHeight: 14
        )
        cursorY = Layout.margin + Layout.headerHeight
    }

    private func finishPage() {
        let dividerY = Layout.page.height - Layout.margin
            - Layout.footerHeight + 2
        UIColor.lightGray.setStroke()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: Layout.margin, y: dividerY))
        path.addLine(
            to: CGPoint(
                x: Layout.page.width - Layout.margin,
                y: dividerY
            )
        )
        path.lineWidth = 0.5
        path.stroke()
        draw(
            "\(Copy.pdfDisclaimer) · 第 \(pageNumber) 页",
            at: CGPoint(x: Layout.margin, y: dividerY + 6),
            width: Layout.contentWidth,
            font: footerFont,
            color: .darkGray,
            lineHeight: 12
        )
    }

    private func newPage() {
        finishPage()
        beginPage()
    }

    private var contentBottom: CGFloat {
        Layout.page.height - Layout.margin - Layout.footerHeight
    }

    private func ensureSpace(_ requiredHeight: CGFloat) {
        if cursorY + requiredHeight > contentBottom {
            newPage()
        }
    }

    private func drawTitle() {
        let title = "就诊摘要"
        let height = textHeight(
            title,
            width: Layout.contentWidth,
            font: titleFont,
            lineHeight: 28
        )
        ensureSpace(height + 8)
        draw(
            title,
            at: CGPoint(x: Layout.margin, y: cursorY),
            width: Layout.contentWidth,
            font: titleFont,
            color: .black,
            lineHeight: 28
        )
        cursorY += height + 4
        let subtitle = "\(payload.rangeName) · 本地整理，不提供诊断"
        let subtitleHeight = textHeight(
            subtitle,
            width: Layout.contentWidth,
            font: footerFont,
            lineHeight: 14
        )
        draw(
            subtitle,
            at: CGPoint(x: Layout.margin, y: cursorY),
            width: Layout.contentWidth,
            font: footerFont,
            color: .darkGray,
            lineHeight: 14
        )
        cursorY += subtitleHeight + Layout.sectionSpacing
    }

    private func drawBrief() {
        for section in payload.brief.sections {
            guard !stopIfCancelled() else { return }
            let headingHeight = textHeight(
                section.title,
                width: Layout.contentWidth,
                font: sectionFont,
                lineHeight: 21
            )
            ensureSpace(headingHeight + Layout.bodyLineHeight + 8)
            draw(
                section.title,
                at: CGPoint(x: Layout.margin, y: cursorY),
                width: Layout.contentWidth,
                font: sectionFont,
                color: .black,
                lineHeight: 21
            )
            cursorY += headingHeight + 4
            for item in section.items {
                guard !stopIfCancelled() else { return }
                let marker = item.sourceMarker.map { " \($0)" } ?? ""
                drawBodyItem("• \(item.text)\(marker)")
            }
            cursorY += Layout.sectionSpacing
        }
        ensureSpace(Layout.bodyLineHeight * 2)
        drawBodyItem(payload.brief.disclaimer, color: .darkGray)
        cursorY += Layout.sectionSpacing
    }

    private func drawRecordAppendix() {
        guard !payload.records.isEmpty else { return }
        drawSectionHeading("记录与结构化指标（\(payload.rangeName)）")
        for record in payload.records {
            guard !stopIfCancelled() else { return }
            let title = "\(payloadDateFormatter.string(from: record.eventDate)) · \(record.title.isEmpty ? record.type.displayName : record.title)"
            let titleHeight = textHeight(
                title,
                width: Layout.contentWidth,
                font: bodyStrongFont,
                lineHeight: Layout.bodyLineHeight
            )
            ensureSpace(titleHeight + Layout.bodyLineHeight + 4)
            draw(
                title,
                at: CGPoint(x: Layout.margin, y: cursorY),
                width: Layout.contentWidth,
                font: bodyStrongFont,
                color: .black,
                lineHeight: Layout.bodyLineHeight
            )
            cursorY += titleHeight + 2
            let summary = record.summary.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !summary.isEmpty {
                drawBodyItem("摘要：\(summary)")
            }
            for measurement in record.measurements {
                guard !stopIfCancelled() else { return }
                let valueText: String
                if let numeric = measurement.numericValue {
                    valueText = numeric.formatted(
                        .number.precision(.fractionLength(0...4))
                    )
                } else if let textual = measurement.textualValue,
                          !textual.isEmpty {
                    valueText = textual
                } else {
                    valueText = "未记录"
                }
                let flag = measurement.abnormalState == .none
                    ? ""
                    : " [\(measurement.abnormalState.rawValue)]"
                drawBodyItem(
                    "指标：\(measurement.name) \(valueText)\(measurement.unit)\(flag)"
                )
            }
            for field in record.structuredFields {
                guard !stopIfCancelled() else { return }
                drawBodyItem("字段：\(field.key) = \(field.value)")
            }
            cursorY += Layout.itemSpacing
        }
        cursorY += Layout.sectionSpacing
    }

    private func drawSources() {
        guard !payload.brief.sources.isEmpty else { return }
        drawSectionHeading("来源")
        for source in payload.brief.sources {
            guard !stopIfCancelled() else { return }
            let value = "\(BriefSource.marker(source.number)) \(payloadDateFormatter.string(from: source.eventDate)) \(source.title) \(source.recordType.displayName)\n记录 ID：\(source.recordID.uuidString)"
            drawBodyItem(value)
        }
    }

    private func drawBrandClosingBlock() {
        let height = CareThreadPDFBranding.standardClosingHeight
        ensureSpace(height + Layout.sectionSpacing)
        CareThreadPDFBranding.drawClosingBlock(
            in: CGRect(
                x: Layout.margin,
                y: cursorY,
                width: Layout.contentWidth,
                height: height
            )
        )
        cursorY += height
    }

    private func drawSectionHeading(_ title: String) {
        let height = textHeight(
            title,
            width: Layout.contentWidth,
            font: sectionFont,
            lineHeight: 21
        )
        ensureSpace(height + Layout.bodyLineHeight)
        draw(
            title,
            at: CGPoint(x: Layout.margin, y: cursorY),
            width: Layout.contentWidth,
            font: sectionFont,
            color: .black,
            lineHeight: 21
        )
        cursorY += height + 4
    }

    private func drawBodyItem(
        _ text: String,
        color: UIColor = .black
    ) {
        guard !stopIfCancelled() else { return }
        let height = textHeight(
            text,
            width: Layout.contentWidth,
            font: bodyFont,
            lineHeight: Layout.bodyLineHeight
        )
        ensureSpace(height + Layout.itemSpacing)
        draw(
            text,
            at: CGPoint(x: Layout.margin, y: cursorY),
            width: Layout.contentWidth,
            font: bodyFont,
            color: color,
            lineHeight: Layout.bodyLineHeight
        )
        cursorY += height + Layout.itemSpacing
    }

    @discardableResult
    private func draw(
        _ text: String,
        at point: CGPoint,
        width: CGFloat,
        font: UIFont,
        color: UIColor,
        lineHeight: CGFloat
    ) -> CGFloat {
        let height = textHeight(
            text,
            width: width,
            font: font,
            lineHeight: lineHeight
        )
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        (text as NSString).draw(
            in: CGRect(
                x: point.x,
                y: point.y,
                width: width,
                height: height + 1
            ),
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
        )
        return height
    }

    private func textHeight(
        _ text: String,
        width: CGFloat,
        font: UIFont,
        lineHeight: CGFloat
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return ceil(
            (text as NSString).boundingRect(
                with: CGSize(
                    width: width,
                    height: .greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: font,
                    .paragraphStyle: style
                ],
                context: nil
            ).height
        )
    }

    private func stopIfCancelled() -> Bool {
        guard shouldCancel() else { return false }
        wasCancelled = true
        return true
    }
}
