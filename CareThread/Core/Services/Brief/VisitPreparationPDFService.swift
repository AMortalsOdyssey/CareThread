import CoreGraphics
import Foundation
import UIKit

enum VisitPreparationPDFError: Error, Equatable {
    case emptyDocument
    case contentExceedsOnePagePolicy
    case outputTooSmall
    case pageCountMismatch
}

struct VisitPreparationPDFService {
    let store: M7TemporaryExportStore

    init(store: M7TemporaryExportStore = M7TemporaryExportStore()) {
        self.store = store
    }

    func exportAsync(
        _ document: VisitPreparationCardDocument
    ) async throws -> M7PDFExportResult {
        let rootURL = store.rootURL
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let backgroundStore = M7TemporaryExportStore(rootURL: rootURL)
            let result = try VisitPreparationPDFService(
                store: backgroundStore
            ).export(document)
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

    func export(
        _ document: VisitPreparationCardDocument
    ) throws -> M7PDFExportResult {
        guard document.hasExportableContent else {
            AppLog.userAction.warning(
                "Visit preparation card export rejected in empty state"
            )
            throw VisitPreparationPDFError.emptyDocument
        }
        guard document.itemCount
                <= VisitPreparationCardPolicy.maximumVisibleItems,
              document.sections
                .flatMap(\.items)
                .allSatisfy({
                    $0.text.count
                        <= VisitPreparationCardPolicy.maximumItemCharacters
                }) else {
            AppLog.userAction.warning(
                "Visit preparation card rejected outside one-page policy"
            )
            throw VisitPreparationPDFError.contentExceedsOnePagePolicy
        }

        let fileURL = try store.preparePDFURL()
        do {
            let renderer = VisitPreparationPDFRenderer(document: document)
            guard renderer.contentFitsOnePage else {
                throw VisitPreparationPDFError.contentExceedsOnePagePolicy
            }
            try renderer.write(to: fileURL)
            try store.protect(fileURL)
            let byteCount = (
                try FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                )[.size] as? NSNumber
            )?.int64Value ?? 0
            guard byteCount > 4_096 else {
                throw VisitPreparationPDFError.outputTooSmall
            }
            guard let pdf = CGPDFDocument(fileURL as CFURL),
                  pdf.numberOfPages == 1 else {
                throw VisitPreparationPDFError.pageCountMismatch
            }
            AppLog.userAction.info(
                "Protected one-page visit preparation PDF exported"
            )
            return M7PDFExportResult(
                fileURL: fileURL,
                byteCount: byteCount,
                pageCount: 1,
                renderedOnMainThread: Thread.isMainThread
            )
        } catch {
            store.remove(fileURL)
            AppLog.vault.error(
                "Visit preparation PDF export failed: \(error.localizedDescription)"
            )
            throw error
        }
    }
}

private final class VisitPreparationPDFRenderer {
    private enum Layout {
        static let pointsPerMillimeter: CGFloat = 72 / 25.4
        static let page = CGRect(
            x: 0,
            y: 0,
            width: 210 * pointsPerMillimeter,
            height: 297 * pointsPerMillimeter
        )
        static let margin: CGFloat = 34
        static let contentWidth = page.width - margin * 2
        static let closingHeight: CGFloat = 60
        static let closingTop = page.height - margin - closingHeight
        static let footerTop = closingTop - 38
    }

    private let document: VisitPreparationCardDocument
    private let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
    private let metaFont = UIFont.systemFont(ofSize: 9, weight: .regular)
    private let sectionFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
    private let bodyFont = UIFont.systemFont(ofSize: 8.5, weight: .regular)
    private let noteFont = UIFont.systemFont(ofSize: 8, weight: .regular)

    init(document: VisitPreparationCardDocument) {
        self.document = document
    }

    var contentFitsOnePage: Bool {
        contentBottomY() <= Layout.footerTop
    }

    func write(to fileURL: URL) throws {
        let renderer = UIGraphicsPDFRenderer(
            bounds: Layout.page,
            format: format()
        )
        try renderer.writePDF(to: fileURL) { context in
            context.beginPage()
            drawPage()
        }
    }

    private func format() -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String:
                Copy.VisitPreparation.pdfTitle,
            kCGPDFContextCreator as String: "CareThread"
        ]
        return format
    }

    private func drawPage() {
        var y = Layout.margin
        CareThreadPDFBranding.drawHeader(
            in: CGRect(
                x: Layout.margin,
                y: y,
                width: Layout.contentWidth,
                height: CareThreadPDFBranding.headerHeight
            )
        )
        y += CareThreadPDFBranding.headerHeight + 3
        draw(
            Copy.VisitPreparation.pdfTitle,
            font: titleFont,
            color: .black,
            rect: CGRect(
                x: Layout.margin,
                y: y,
                width: Layout.contentWidth,
                height: 26
            )
        )
        y += 29
        draw(
            String(
                format: Copy.VisitPreparation.pdfMeta,
                document.memberName,
                BriefFormatting.day.string(from: document.generatedAt)
            ),
            font: metaFont,
            color: .darkGray,
            rect: CGRect(
                x: Layout.margin,
                y: y,
                width: Layout.contentWidth,
                height: 14
            )
        )
        y += 20

        for section in document.sections {
            draw(
                section.title,
                font: sectionFont,
                color: .black,
                rect: CGRect(
                    x: Layout.margin,
                    y: y,
                    width: Layout.contentWidth,
                    height: 16
                )
            )
            y += 17
            for item in section.items {
                let text = "• \(item.text)"
                let height = itemHeight(for: text)
                draw(
                    text,
                    font: bodyFont,
                    color: .black,
                    rect: CGRect(
                        x: Layout.margin,
                        y: y,
                        width: Layout.contentWidth,
                        height: height
                    )
                )
                y += height + 2
            }
            y += 4
        }

        var noteY = y
        if document.omittedItemCount > 0 {
            draw(
                String(
                    format: Copy.VisitPreparation.omittedCount,
                    document.omittedItemCount
                ),
                font: noteFont,
                color: .darkGray,
                rect: CGRect(
                    x: Layout.margin,
                    y: noteY,
                    width: Layout.contentWidth,
                    height: 14
                )
            )
            noteY += 15
        }
        if document.shortenedItemCount > 0 {
            draw(
                String(
                    format: Copy.VisitPreparation.shortenedCount,
                    document.shortenedItemCount
                ),
                font: noteFont,
                color: .darkGray,
                rect: CGRect(
                    x: Layout.margin,
                    y: noteY,
                    width: Layout.contentWidth,
                    height: 14
                )
            )
            noteY += 15
        }

        draw(
            document.disclaimer,
            font: noteFont,
            color: .darkGray,
            rect: CGRect(
                x: Layout.margin,
                y: Layout.footerTop,
                width: Layout.contentWidth,
                height: 36
            )
        )
        CareThreadPDFBranding.drawClosingBlock(
            in: CGRect(
                x: Layout.margin,
                y: Layout.closingTop,
                width: Layout.contentWidth,
                height: Layout.closingHeight
            )
        )
    }

    private func draw(
        _ text: String,
        font: UIFont,
        color: UIColor,
        rect: CGRect
    ) {
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .foregroundColor: color
            ],
            context: nil
        )
    }

    private func contentBottomY() -> CGFloat {
        var y = Layout.margin
            + CareThreadPDFBranding.headerHeight
            + 3
            + 29
            + 20
        for section in document.sections {
            y += 17
            for item in section.items {
                let text = "• \(item.text)"
                y += itemHeight(for: text) + 2
            }
            y += 4
        }
        if document.omittedItemCount > 0 {
            y += 15
        }
        if document.shortenedItemCount > 0 {
            y += 15
        }
        return y
    }

    private func itemHeight(for text: String) -> CGFloat {
        min(
            25,
            ceil(
                text.boundingRect(
                    with: CGSize(
                        width: Layout.contentWidth,
                        height: 26
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: bodyFont],
                    context: nil
                ).height
            )
        )
    }
}
