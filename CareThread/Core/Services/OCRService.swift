import CoreGraphics
import Foundation
import UIKit
import Vision

struct TextBlock: Equatable, Sendable {
    var text: String
    var box: CGRect
    var confidence: Float
}

struct OCRPageResult: Equatable, Sendable {
    var pageIndex: Int
    var blocks: [TextBlock]

    var text: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    var averageConfidence: Float {
        guard !blocks.isEmpty else { return 0 }
        return blocks.reduce(0) { $0 + $1.confidence } / Float(blocks.count)
    }
}

enum OCREngineError: Error, Equatable {
    case invalidImage
    case recognitionFailed(String)
}

protocol OCREngine {
    var identifier: String { get }
    func recognize(_ image: UIImage, pageIndex: Int) async throws -> OCRPageResult
}

struct VisionOCREngine: OCREngine {
    let identifier = "apple-vision"

    func recognize(_ image: UIImage, pageIndex: Int = 0) async throws -> OCRPageResult {
        guard let cgImage = image.cgImage else {
            AppLog.extraction.error("Vision OCR received an image without CGImage backing")
            throw OCREngineError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    AppLog.extraction.error(
                        "Vision OCR failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                    continuation.resume(
                        throwing: OCREngineError.recognitionFailed(error.localizedDescription)
                    )
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let blocks = observations.compactMap { observation -> TextBlock? in
                    guard let candidate = observation.topCandidates(1).first else {
                        return nil
                    }
                    return TextBlock(
                        text: candidate.string,
                        box: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                }
                .sorted { lhs, rhs in
                    if abs(lhs.box.maxY - rhs.box.maxY) > 0.01 {
                        return lhs.box.maxY > rhs.box.maxY
                    }
                    return lhs.box.minX < rhs.box.minX
                }
                continuation.resume(returning: OCRPageResult(pageIndex: pageIndex, blocks: blocks))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            do {
                try handler.perform([request])
            } catch {
                AppLog.extraction.error(
                    "Vision request handler failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                continuation.resume(
                    throwing: OCREngineError.recognitionFailed(error.localizedDescription)
                )
            }
        }
    }
}

enum TextFixtureRenderer {
    static func image(
        text: String,
        width: CGFloat = 1_240,
        fontSize: CGFloat = 30,
        margin: CGFloat = 64
    ) -> UIImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let availableWidth = width - margin * 2
        let measured = attributed.boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let height = max(measured.height + margin * 2, 240)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
            attributed.draw(
                with: CGRect(x: margin, y: margin, width: availableWidth, height: measured.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }
    }
}
