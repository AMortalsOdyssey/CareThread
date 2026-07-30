import Foundation
import PDFKit
import UIKit

struct M3RecognitionOutput {
    let text: String
    let averageConfidence: Float
    let names: [DetectedNameCandidate]
    let extraction: ExtractionResult
}

enum M3CaptureRecognitionPipeline {
    static let renderMaximumPixelSize: CGFloat = 2_048

    static func recognize(
        page: M3CapturePageAsset,
        pageIndex: Int,
        vault: CaptureVaultService
    ) async throws -> M3RecognitionOutput {
        try Task.checkCancellation()
        guard (page.previewRelativePath ?? page.relativePath) != nil else {
            return M3RecognitionOutput(
                text: "",
                averageConfidence: 0,
                names: [],
                extraction: .empty
            )
        }
        let image = try await renderPreview(page: page, vault: vault)
        let recognitionTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await VisionOCREngine().recognize(image, pageIndex: pageIndex)
        }
        let result = try await withTaskCancellationHandler {
            try await recognitionTask.value
        } onCancel: {
            recognitionTask.cancel()
        }
        let extraction = try await extractText(result.text)
        return M3RecognitionOutput(
            text: result.text,
            averageConfidence: result.averageConfidence,
            names: detectNames(
                in: result.text,
                averageConfidence: result.averageConfidence
            ),
            extraction: extraction
        )
    }

    static func renderPreview(
        page: M3CapturePageAsset,
        vault: CaptureVaultService
    ) async throws -> UIImage {
        guard let relativePath = page.previewRelativePath ?? page.relativePath else {
            throw OCREngineError.invalidImage
        }
        let url = try vault.url(for: relativePath)
        let renderTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image: UIImage
            if page.kind == .pdf {
                guard let document = PDFDocument(url: url),
                      let pdfPage = document.page(at: page.pdfPageIndex ?? 0) else {
                    throw OCREngineError.invalidImage
                }
                let bounds = pdfPage.bounds(for: .mediaBox)
                let longest = max(bounds.width, bounds.height)
                guard longest > 0 else { throw OCREngineError.invalidImage }
                let scale = min(1, renderMaximumPixelSize / longest)
                image = pdfPage.thumbnail(
                    of: CGSize(
                        width: max(1, bounds.width * scale),
                        height: max(1, bounds.height * scale)
                    ),
                    for: .mediaBox
                )
            } else {
                guard let loaded = UIImage(contentsOfFile: url.path) else {
                    throw OCREngineError.invalidImage
                }
                image = loaded
            }
            return rotate(image, quarterTurns: page.rotationQuarterTurns)
        }
        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    static func extractText(_ text: String) async throws -> ExtractionResult {
        let extractionTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return ExtractionEngine().extract(
                text,
                today: Date(),
                engineIdentifier: VisionOCREngine().identifier
            )
        }
        return try await withTaskCancellationHandler {
            try await extractionTask.value
        } onCancel: {
            extractionTask.cancel()
        }
    }

    static func outputForExistingText(
        _ text: String,
        detectedNames: [DetectedNameCandidate]
    ) async throws -> M3RecognitionOutput {
        let extraction = try await extractText(text)
        return M3RecognitionOutput(
            text: text,
            averageConfidence: 1,
            names: detectedNames,
            extraction: extraction
        )
    }

    /*
     Grouping intentionally consumes the persisted per-page OCR/extraction
     evidence. It never assigns a report; it only produces a review preview.
     */
    static func groupingEvidence(
        for pages: [M3CapturePageAsset],
        source: M3CaptureSource
    ) -> [ImportPageEvidence] {
        pages.map { page in
            let lines = (page.ocrText ?? "")
                .split(separator: "\n")
                .map(String.init)
            let extraction = page.machineExtraction ?? .empty
            let importSource: ImportPageSource
            switch page.captureSource ?? source {
            case .camera:
                importSource = .visionKitScan
            case .photos, .fixture:
                importSource = .photoSelection
            case .files:
                importSource = page.kind == .pdf ? .multiPagePDF : .photoSelection
            case .manual:
                importSource = .photoSelection
            }
            let isFirstPage = (page.pdfPageIndex ?? 0) == 0
            let structureScore: Double =
                (page.ocrText?.contains("姓名") == true
                    || page.ocrText?.contains("报告") == true)
                ? 0.9
                : 0.2
            return ImportPageEvidence(
                pageID: page.id,
                sourceOrder: page.sourceOrder,
                sourceSessionID: page.sourceSessionID,
                source: importSource,
                names: page.detectedNames.map {
                    ImportNameEvidence(value: $0.name, confidence: $0.confidence)
                },
                hospital: extraction.hospital,
                eventDate: extraction.eventDate,
                capturedAt: Date(),
                reportTitle: extraction.title.isEmpty ? nil : extraction.title,
                reportNumber: nil,
                pageNumber: page.kind == .pdf ? (page.pdfPageIndex ?? 0) + 1 : nil,
                totalPages: nil,
                topOCRLines: Array(lines.prefix(12)),
                bottomOCRLines: Array(lines.suffix(12)),
                firstPageStructureScore: isFirstPage ? structureScore : 0
            )
        }
    }

    private static func detectNames(
        in text: String,
        averageConfidence: Float
    ) -> [DetectedNameCandidate] {
        let pattern = #"姓名\s*[:：]?\s*([\p{Han}·]{2,20})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        var seen = Set<String>()
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let name = String(text[range])
            let normalized = MemberIdentity.normalize(name)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            let confidence = Double(averageConfidence)
            return DetectedNameCandidate(
                name: name,
                confidence: confidence,
                isReliable: confidence >= 0.85
            )
        }
    }

    private static func rotate(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swapsAxes = turns.isMultiple(of: 2) == false
        let outputSize = swapsAxes
            ? CGSize(width: image.size.height, height: image.size.width)
            : image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            cg.rotate(by: CGFloat(turns) * .pi / 2)
            image.draw(
                in: CGRect(
                    x: -image.size.width / 2,
                    y: -image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                )
            )
        }
    }
}
