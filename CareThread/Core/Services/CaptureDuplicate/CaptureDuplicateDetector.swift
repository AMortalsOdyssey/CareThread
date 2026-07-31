import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Vision

enum CaptureDuplicateEvidence: String, Equatable, Sendable {
    case exactFileHash
    case visualContentHash
    case ocrContentOverlap

    var isHardBlock: Bool {
        self == .exactFileHash
    }
}

enum CaptureDuplicateScope: Equatable, Sendable {
    case currentImport
    case savedRecord
}

struct CaptureDuplicateMatch: Equatable, Identifiable, Sendable {
    let id = UUID()
    let evidence: CaptureDuplicateEvidence
    let scope: CaptureDuplicateScope
    let similarity: Double
    let candidateID: UUID
    let otherCandidateID: UUID?
    let existingRecordID: UUID?
    let existingRecordTitle: String?
    let existingRecordDate: Date?
    let candidateDisplayName: String

    var isHardBlock: Bool {
        evidence.isHardBlock
    }
}

struct CaptureDuplicateCandidateSnapshot: Sendable {
    let id: UUID
    let displayName: String
    let sha256: String
    let visualURL: URL?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let ocrText: String
}

struct CaptureDuplicateAttachmentSnapshot: Sendable {
    let id: UUID
    let sha256: String
    let visualURL: URL?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

struct CaptureDuplicateRecordSnapshot: Sendable {
    let id: UUID
    let title: String
    let eventDate: Date
    let ocrText: String
    let attachments: [CaptureDuplicateAttachmentSnapshot]
}

enum CaptureDuplicateDetectionError: Error, Equatable {
    case invalidCaptureInput
    case libraryChangedRepeatedly
}

private struct CaptureDuplicateRecordRevision: Equatable, Sendable {
    let id: UUID
    let updatedAt: Date
    let contentRevision: Int
    let attachmentSignatures: [String]
}

private struct CaptureDuplicateLibraryRevision: Equatable, Sendable {
    let records: [CaptureDuplicateRecordRevision]
}

enum CaptureDuplicateTextFingerprint {
    static let minimumNormalizedCharacters = 36
    static let jaccardThreshold = 0.82
    static let containmentThreshold = 0.92
    static let containmentJaccardFloor = 0.55
    static let strongContainmentThreshold = 0.97
    static let strongContainmentMinimumCharacters = 80

    static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
        .unicodeScalars
        .filter {
            CharacterSet.alphanumerics.contains($0)
                || ($0.value >= 0x3400 && $0.value <= 0x9FFF)
        }
        .map(String.init)
        .joined()
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double? {
        guard !hasHardDiscriminatorConflict(lhs, rhs) else { return nil }
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard left.count >= minimumNormalizedCharacters,
              right.count >= minimumNormalizedCharacters else {
            return nil
        }
        let leftShingles = shingles(left)
        let rightShingles = shingles(right)
        guard !leftShingles.isEmpty, !rightShingles.isEmpty else { return nil }
        let intersection = leftShingles.intersection(rightShingles).count
        let union = leftShingles.union(rightShingles).count
        let jaccard = Double(intersection) / Double(max(1, union))
        let containment = Double(intersection)
            / Double(max(1, min(leftShingles.count, rightShingles.count)))
        guard jaccard >= jaccardThreshold
                || (containment >= containmentThreshold
                    && jaccard >= containmentJaccardFloor)
                || (containment >= strongContainmentThreshold
                    && min(left.count, right.count)
                        >= strongContainmentMinimumCharacters) else {
            return nil
        }
        return max(jaccard, containment)
    }

    /// A hospital template can remain almost identical while the actual visit
    /// date or report number changes. Those explicit conflicts are stronger
    /// evidence than layout/text overlap and suppress an OCR duplicate alert.
    static func hasHardDiscriminatorConflict(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let leftDates = discriminatorTokens(
            lhs,
            pattern:
                #"(?<!\d)(?:19|20)\d{2}\s*[年./-]\s*(?:0?[1-9]|1[0-2])\s*[月./-]\s*(?:0?[1-9]|[12]\d|3[01])\s*日?"#
        )
        let rightDates = discriminatorTokens(
            rhs,
            pattern:
                #"(?<!\d)(?:19|20)\d{2}\s*[年./-]\s*(?:0?[1-9]|1[0-2])\s*[月./-]\s*(?:0?[1-9]|[12]\d|3[01])\s*日?"#
        )
        if !leftDates.isEmpty, !rightDates.isEmpty,
           leftDates.isDisjoint(with: rightDates) {
            return true
        }
        let reportPattern =
            #"(?:报告|检查|检验|申请|病理)\s*(?:编号|号|序号|ID|NO\.?)\s*[:：]?\s*[A-Z0-9][A-Z0-9._/-]{3,}"#
        let leftReportIDs = discriminatorTokens(lhs, pattern: reportPattern)
        let rightReportIDs = discriminatorTokens(rhs, pattern: reportPattern)
        return !leftReportIDs.isEmpty
            && !rightReportIDs.isEmpty
            && leftReportIDs.isDisjoint(with: rightReportIDs)
    }

    private static func discriminatorTokens(
        _ text: String,
        pattern: String
    ) -> Set<String> {
        let folded = text.folding(
            options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let range = NSRange(folded.startIndex..., in: folded)
        return Set(expression.matches(in: folded, range: range).compactMap {
            guard let valueRange = Range($0.range, in: folded) else { return nil }
            return normalized(String(folded[valueRange]))
        })
    }

    private static func shingles(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 3 else { return [] }
        return Set((0...(characters.count - 3)).map {
            String(characters[$0...($0 + 2)])
        })
    }
}

struct CapturePerceptualHashValue: Sendable {
    let dctHashes: [UInt64]
    let blockHashes: [UInt64]
    let differenceHashes: [UInt64]
}

enum CapturePerceptualImageHash {
    static let maximumHammingDistance = 5
    static let maximumBlockHammingDistance = 9
    static let maximumDifferenceHammingDistance = 10
    static let algorithmIdentifier =
        "carethread-phash-dct64-block64-dhash64-rot4-multicrop-v3"
    private static let cropScales: [CGFloat] = [1, 0.94, 0.90, 0.86]
    private static let cosineTable: [[Double]] = (0..<8).map { frequency in
        (0..<32).map { position in
            cos(Double((2 * position + 1) * frequency) * .pi / 64)
        }
    }

    static func make(url: URL) -> CapturePerceptualHashValue? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 512,
                      kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary
              ) else {
            return nil
        }
        var dctHashes: [UInt64] = []
        var blockHashes: [UInt64] = []
        var differenceHashes: [UInt64] = []
        for scale in cropScales {
            guard let pixels = grayscalePixels(image, cropScale: scale) else {
                continue
            }
            let coefficients = lowFrequencyDCT(pixels)
            let valuesWithoutDC = Array(coefficients.dropFirst()).sorted()
            guard !valuesWithoutDC.isEmpty else { continue }
            let median = valuesWithoutDC[valuesWithoutDC.count / 2]
            var hash: UInt64 = 0
            for (index, value) in coefficients.enumerated() where value > median {
                hash |= UInt64(1) << UInt64(index)
            }
            dctHashes.append(hash)
            var orientedPixels = pixels
            for _ in 0..<4 {
                blockHashes.append(blockHash(orientedPixels))
                differenceHashes.append(differenceHash(orientedPixels))
                orientedPixels = rotatedQuarterTurn(orientedPixels)
            }
        }
        guard !dctHashes.isEmpty, !blockHashes.isEmpty,
              !differenceHashes.isEmpty else {
            return nil
        }
        return CapturePerceptualHashValue(
            dctHashes: Array(Set(dctHashes)),
            blockHashes: Array(Set(blockHashes)),
            differenceHashes: Array(Set(differenceHashes))
        )
    }

    static func similarity(
        _ lhs: CapturePerceptualHashValue,
        _ rhs: CapturePerceptualHashValue
    ) -> Double? {
        if let distance = minimumHammingDistance(
            lhs.dctHashes,
            rhs.dctHashes
        ), distance <= maximumHammingDistance {
            return 1 - (Double(distance) / 64)
        }
        guard let blockDistance = minimumHammingDistance(
            lhs.blockHashes,
            rhs.blockHashes
        ), blockDistance <= maximumBlockHammingDistance,
              let differenceDistance = minimumHammingDistance(
                  lhs.differenceHashes,
                  rhs.differenceHashes
              ), differenceDistance <= maximumDifferenceHammingDistance else {
            return nil
        }
        return 1 - (Double(max(blockDistance, differenceDistance)) / 64)
    }

    static func minimumHammingDistance(
        _ lhs: [UInt64],
        _ rhs: [UInt64]
    ) -> Int? {
        lhs.flatMap { left in
            rhs.map { right in (left ^ right).nonzeroBitCount }
        }.min()
    }

    private static func grayscalePixels(
        _ image: CGImage,
        cropScale: CGFloat
    ) -> [Double]? {
        let dimension = 32
        let scale = min(1, max(0.5, cropScale))
        let cropRect = CGRect(
            x: CGFloat(image.width) * (1 - scale) / 2,
            y: CGFloat(image.height) * (1 - scale) / 2,
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        ).integral
        guard let cropped = image.cropping(to: cropRect) else { return nil }
        var bytes = [UInt8](repeating: 0, count: dimension * dimension)
        guard let context = CGContext(
            data: &bytes,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: dimension, height: dimension)
        )
        return bytes.map(Double.init)
    }

    private static func lowFrequencyDCT(_ pixels: [Double]) -> [Double] {
        let sourceDimension = 32
        let resultDimension = 8
        var result = [Double](repeating: 0, count: resultDimension * resultDimension)
        for verticalFrequency in 0..<resultDimension {
            for horizontalFrequency in 0..<resultDimension {
                var sum = 0.0
                for y in 0..<sourceDimension {
                    let verticalCosine = cosineTable[verticalFrequency][y]
                    for x in 0..<sourceDimension {
                        let horizontalCosine = cosineTable[horizontalFrequency][x]
                        sum += pixels[y * sourceDimension + x]
                            * horizontalCosine
                            * verticalCosine
                    }
                }
                result[verticalFrequency * resultDimension + horizontalFrequency] = sum
            }
        }
        return result
    }

    private static func blockHash(_ pixels: [Double]) -> UInt64 {
        var blockAverages: [Double] = []
        blockAverages.reserveCapacity(64)
        for blockY in 0..<8 {
            for blockX in 0..<8 {
                var sum = 0.0
                for y in (blockY * 4)..<(blockY * 4 + 4) {
                    for x in (blockX * 4)..<(blockX * 4 + 4) {
                        sum += pixels[y * 32 + x]
                    }
                }
                blockAverages.append(sum / 16)
            }
        }
        let sorted = blockAverages.sorted()
        let median = sorted[sorted.count / 2]
        var hash: UInt64 = 0
        for (index, value) in blockAverages.enumerated() where value < median {
            hash |= UInt64(1) << UInt64(index)
        }
        return hash
    }

    private static func differenceHash(_ pixels: [Double]) -> UInt64 {
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            let sampleY = Int((Double(y) + 0.5) * 32 / 8)
            for x in 0..<8 {
                let leftX = Int((Double(x) + 0.5) * 32 / 9)
                let rightX = Int((Double(x + 1) + 0.5) * 32 / 9)
                let left = pixels[min(31, sampleY) * 32 + min(31, leftX)]
                let right = pixels[min(31, sampleY) * 32 + min(31, rightX)]
                if left > right {
                    hash |= UInt64(1) << UInt64(bit)
                }
                bit += 1
            }
        }
        return hash
    }

    private static func rotatedQuarterTurn(_ pixels: [Double]) -> [Double] {
        var rotated = [Double](repeating: 0, count: pixels.count)
        for y in 0..<32 {
            for x in 0..<32 {
                rotated[x * 32 + (31 - y)] = pixels[y * 32 + x]
            }
        }
        return rotated
    }
}

private final class CapturePHashBox: NSObject {
    let value: CapturePerceptualHashValue

    init(_ value: CapturePerceptualHashValue) {
        self.value = value
    }
}

/// A rebuildable, process-local acceleration only. Keys contain the algorithm
/// version plus immutable file SHA; no patient, OCR, path, or medical metadata
/// is retained. NSCache releases values under memory pressure.
private final class CapturePHashMemoryCache: @unchecked Sendable {
    static let shared = CapturePHashMemoryCache()

    private let storage = NSCache<NSString, CapturePHashBox>()

    private init() {
        storage.countLimit = 2_048
    }

    func value(
        sha256: String,
        url: URL
    ) -> CapturePerceptualHashValue? {
        let key = "\(CapturePerceptualImageHash.algorithmIdentifier):\(sha256.lowercased())"
        if let hit = storage.object(forKey: key as NSString) {
            return hit.value
        }
        guard let value = CapturePerceptualImageHash.make(url: url) else {
            return nil
        }
        storage.setObject(CapturePHashBox(value), forKey: key as NSString)
        return value
    }
}

enum CaptureVisionImageFingerprint {
    /// Apple does not publish a universal semantic cutoff. This conservative
    /// value is covered by fictional re-photograph and unrelated-document
    /// fixtures on the deployment runtime. It is only a non-persistent iOS
    /// fallback; the portable DCT pHash remains the stable algorithm.
    static let maximumDistance: Float = 0.30

    static func make(url: URL) -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 512,
                      kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary
              ) else {
            return nil
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    static func similarity(
        _ lhs: VNFeaturePrintObservation,
        _ rhs: VNFeaturePrintObservation
    ) -> Double? {
        guard let distance = distance(lhs, rhs),
              distance <= maximumDistance else {
            return nil
        }
        return 1 - Double(min(1, distance))
    }

    static func distance(
        _ lhs: VNFeaturePrintObservation,
        _ rhs: VNFeaturePrintObservation
    ) -> Float? {
        var distance: Float = 0
        guard (try? lhs.computeDistance(&distance, to: rhs)) != nil else {
            return nil
        }
        return distance
    }
}

enum CaptureDuplicateDetector {
    static func strongestMatch(
        candidates: [CaptureDuplicateCandidateSnapshot],
        records: [CaptureDuplicateRecordSnapshot]
    ) -> CaptureDuplicateMatch? {
        guard !Task.isCancelled else { return nil }
        if let exact = exactMatch(candidates: candidates, records: records) {
            return exact
        }
        guard !Task.isCancelled else { return nil }
        if let visual = perceptualHashMatch(
            candidates: candidates,
            records: records
        ) {
            return visual
        }
        guard !Task.isCancelled else { return nil }
        if let text = textMatch(candidates: candidates, records: records) {
            return text
        }
        // Vision is deliberately the last and lazy fallback. Most duplicates
        // resolve through SHA, the portable pHash, or OCR without paying for a
        // feature print. It remains a true fallback after OCR misses: a long
        // but noisy OCR result must not disable visual re-photograph detection.
        return visionFeatureMatch(candidates: candidates, records: records)
    }

    private static func exactMatch(
        candidates: [CaptureDuplicateCandidateSnapshot],
        records: [CaptureDuplicateRecordSnapshot]
    ) -> CaptureDuplicateMatch? {
        for leftIndex in candidates.indices {
            guard !Task.isCancelled else { return nil }
            for rightIndex in candidates.indices where rightIndex > leftIndex {
                guard candidates[leftIndex].sha256 == candidates[rightIndex].sha256 else {
                    continue
                }
                return CaptureDuplicateMatch(
                    evidence: .exactFileHash,
                    scope: .currentImport,
                    similarity: 1,
                    candidateID: candidates[rightIndex].id,
                    otherCandidateID: candidates[leftIndex].id,
                    existingRecordID: nil,
                    existingRecordTitle: nil,
                    existingRecordDate: nil,
                    candidateDisplayName: candidates[rightIndex].displayName
                )
            }
        }
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            for record in records {
                guard record.attachments.contains(where: {
                    $0.sha256 == candidate.sha256
                }) else {
                    continue
                }
                return savedRecordMatch(
                    evidence: .exactFileHash,
                    similarity: 1,
                    candidate: candidate,
                    record: record
                )
            }
        }
        return nil
    }

    private static func perceptualHashMatch(
        candidates: [CaptureDuplicateCandidateSnapshot],
        records: [CaptureDuplicateRecordSnapshot]
    ) -> CaptureDuplicateMatch? {
        var candidateHashes: [
            (CaptureDuplicateCandidateSnapshot, CapturePerceptualHashValue?)
        ] = []
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            candidateHashes.append(
                (
                    candidate,
                    candidate.visualURL.flatMap {
                        CapturePHashMemoryCache.shared.value(
                            sha256: candidate.sha256,
                            url: $0
                        )
                    }
                )
            )
        }
        var best: CaptureDuplicateMatch?
        for leftIndex in candidateHashes.indices {
            guard !Task.isCancelled else { return nil }
            guard let leftHash = candidateHashes[leftIndex].1 else { continue }
            for rightIndex in candidateHashes.indices where rightIndex > leftIndex {
                // Do not hard-filter by aspect ratio. Re-photographing with
                // perspective correction or cropping legitimately changes it.
                guard !CaptureDuplicateTextFingerprint.hasHardDiscriminatorConflict(
                    candidateHashes[leftIndex].0.ocrText,
                    candidateHashes[rightIndex].0.ocrText
                ), let rightHash = candidateHashes[rightIndex].1,
                   let similarity = CapturePerceptualImageHash.similarity(
                       leftHash,
                       rightHash
                   ) else {
                    continue
                }
                best = stronger(
                    best,
                    CaptureDuplicateMatch(
                        evidence: .visualContentHash,
                        scope: .currentImport,
                        similarity: similarity,
                        candidateID: candidateHashes[rightIndex].0.id,
                        otherCandidateID: candidateHashes[leftIndex].0.id,
                        existingRecordID: nil,
                        existingRecordTitle: nil,
                        existingRecordDate: nil,
                        candidateDisplayName: candidateHashes[rightIndex].0.displayName
                    )
                )
            }
        }

        var historicalHashCache: [URL: CapturePerceptualHashValue] = [:]
        for (candidate, candidateHash) in candidateHashes {
            guard !Task.isCancelled else { return nil }
            guard let candidateHash else { continue }
            for record in records {
                for attachment in record.attachments {
                    guard !Task.isCancelled else { return nil }
                    guard !CaptureDuplicateTextFingerprint.hasHardDiscriminatorConflict(
                        candidate.ocrText,
                        record.ocrText
                    ), let url = attachment.visualURL else {
                        continue
                    }
                    let historicalHash: CapturePerceptualHashValue?
                    if let cached = historicalHashCache[url] {
                        historicalHash = cached
                    } else {
                        let value = CapturePHashMemoryCache.shared.value(
                            sha256: attachment.sha256,
                            url: url
                        )
                        historicalHashCache[url] = value
                        historicalHash = value
                    }
                    guard let historicalHash,
                          let similarity = CapturePerceptualImageHash.similarity(
                              candidateHash,
                              historicalHash
                          ) else {
                        continue
                    }
                    best = stronger(
                        best,
                        savedRecordMatch(
                            evidence: .visualContentHash,
                            similarity: similarity,
                            candidate: candidate,
                            record: record
                        )
                    )
                }
            }
        }
        return best
    }

    private static func visionFeatureMatch(
        candidates: [CaptureDuplicateCandidateSnapshot],
        records: [CaptureDuplicateRecordSnapshot]
    ) -> CaptureDuplicateMatch? {
        var candidatePrints: [
            (CaptureDuplicateCandidateSnapshot, VNFeaturePrintObservation?)
        ] = []
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            candidatePrints.append(
                (candidate, candidate.visualURL.flatMap(CaptureVisionImageFingerprint.make))
            )
        }
        var best: CaptureDuplicateMatch?
        for leftIndex in candidatePrints.indices {
            guard !Task.isCancelled else { return nil }
            guard let leftPrint = candidatePrints[leftIndex].1 else { continue }
            for rightIndex in candidatePrints.indices where rightIndex > leftIndex {
                guard !CaptureDuplicateTextFingerprint.hasHardDiscriminatorConflict(
                    candidatePrints[leftIndex].0.ocrText,
                    candidatePrints[rightIndex].0.ocrText
                ), let rightPrint = candidatePrints[rightIndex].1,
                   let similarity = CaptureVisionImageFingerprint.similarity(
                       leftPrint,
                       rightPrint
                   ) else {
                    continue
                }
                best = stronger(
                    best,
                    CaptureDuplicateMatch(
                        evidence: .visualContentHash,
                        scope: .currentImport,
                        similarity: similarity,
                        candidateID: candidatePrints[rightIndex].0.id,
                        otherCandidateID: candidatePrints[leftIndex].0.id,
                        existingRecordID: nil,
                        existingRecordTitle: nil,
                        existingRecordDate: nil,
                        candidateDisplayName: candidatePrints[rightIndex].0.displayName
                    )
                )
            }
        }

        var historicalPrintCache: [URL: VNFeaturePrintObservation] = [:]
        for (candidate, candidatePrint) in candidatePrints {
            guard !Task.isCancelled else { return nil }
            guard let candidatePrint else { continue }
            for record in records {
                for attachment in record.attachments {
                    guard !Task.isCancelled else { return nil }
                    guard !CaptureDuplicateTextFingerprint.hasHardDiscriminatorConflict(
                        candidate.ocrText,
                        record.ocrText
                    ), let url = attachment.visualURL else {
                        continue
                    }
                    let historicalPrint: VNFeaturePrintObservation?
                    if let cached = historicalPrintCache[url] {
                        historicalPrint = cached
                    } else {
                        let value = CaptureVisionImageFingerprint.make(url: url)
                        historicalPrintCache[url] = value
                        historicalPrint = value
                    }
                    guard let historicalPrint,
                          let similarity = CaptureVisionImageFingerprint.similarity(
                              candidatePrint,
                              historicalPrint
                          ) else {
                        continue
                    }
                    best = stronger(
                        best,
                        savedRecordMatch(
                            evidence: .visualContentHash,
                            similarity: similarity,
                            candidate: candidate,
                            record: record
                        )
                    )
                }
            }
        }
        return best
    }

    private static func textMatch(
        candidates: [CaptureDuplicateCandidateSnapshot],
        records: [CaptureDuplicateRecordSnapshot]
    ) -> CaptureDuplicateMatch? {
        var best: CaptureDuplicateMatch?
        for leftIndex in candidates.indices {
            guard !Task.isCancelled else { return nil }
            for rightIndex in candidates.indices where rightIndex > leftIndex {
                guard let similarity = CaptureDuplicateTextFingerprint.similarity(
                    candidates[leftIndex].ocrText,
                    candidates[rightIndex].ocrText
                ) else {
                    continue
                }
                best = stronger(
                    best,
                    CaptureDuplicateMatch(
                        evidence: .ocrContentOverlap,
                        scope: .currentImport,
                        similarity: similarity,
                        candidateID: candidates[rightIndex].id,
                        otherCandidateID: candidates[leftIndex].id,
                        existingRecordID: nil,
                        existingRecordTitle: nil,
                        existingRecordDate: nil,
                        candidateDisplayName: candidates[rightIndex].displayName
                    )
                )
            }
        }
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            for record in records {
                guard let similarity = CaptureDuplicateTextFingerprint.similarity(
                    candidate.ocrText,
                    record.ocrText
                ) else {
                    continue
                }
                best = stronger(
                    best,
                    savedRecordMatch(
                        evidence: .ocrContentOverlap,
                        similarity: similarity,
                        candidate: candidate,
                        record: record
                    )
                )
            }
        }
        let aggregateText = candidates.map(\.ocrText).joined(separator: "\n")
        if let firstCandidate = candidates.first {
            for record in records {
                guard !Task.isCancelled else { return nil }
                guard let similarity = CaptureDuplicateTextFingerprint.similarity(
                    aggregateText,
                    record.ocrText
                ) else {
                    continue
                }
                best = stronger(
                    best,
                    savedRecordMatch(
                        evidence: .ocrContentOverlap,
                        similarity: similarity,
                        candidate: firstCandidate,
                        record: record
                    )
                )
            }
        }
        return best
    }

    private static func savedRecordMatch(
        evidence: CaptureDuplicateEvidence,
        similarity: Double,
        candidate: CaptureDuplicateCandidateSnapshot,
        record: CaptureDuplicateRecordSnapshot
    ) -> CaptureDuplicateMatch {
        CaptureDuplicateMatch(
            evidence: evidence,
            scope: .savedRecord,
            similarity: similarity,
            candidateID: candidate.id,
            otherCandidateID: nil,
            existingRecordID: record.id,
            existingRecordTitle: record.title,
            existingRecordDate: record.eventDate,
            candidateDisplayName: candidate.displayName
        )
    }

    private static func stronger(
        _ current: CaptureDuplicateMatch?,
        _ candidate: CaptureDuplicateMatch
    ) -> CaptureDuplicateMatch {
        guard let current else { return candidate }
        return candidate.similarity > current.similarity ? candidate : current
    }
}

@MainActor
struct CaptureDuplicateDetectionService {
    let context: ModelContext
    let vault: CaptureVaultService

    func scan(
        patientID: UUID,
        pages: [M3CapturePageAsset]
    ) async throws -> CaptureDuplicateMatch? {
        var textByAssetID: [UUID: [String]] = [:]
        for page in pages {
            guard let stagedAssetID = page.stagedAssetID else { continue }
            if let text = MemberIdentity.optionalTrimmed(page.ocrText) {
                textByAssetID[stagedAssetID, default: []].append(text)
            }
        }
        return try await scan(
            patientID: patientID,
            stagedAssets: try stagedAssets(for: pages),
            ocrTextByAssetID: textByAssetID.mapValues {
                $0.joined(separator: "\n")
            }
        )
    }

    func scan(
        patientID: UUID,
        stagedAssets: [StagedCaptureAsset],
        ocrTextByAssetID: [UUID: String]
    ) async throws -> CaptureDuplicateMatch? {
        guard !stagedAssets.isEmpty else {
            throw CaptureDuplicateDetectionError.invalidCaptureInput
        }
        // SwiftData is read on MainActor. If another scene commits for this
        // member while image work is detached, rebuild and retry. Once a
        // stable result returns, the caller enters its synchronous save path,
        // so another scene cannot interleave a commit on MainActor.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let input = try makeInput(
                patientID: patientID,
                stagedAssets: stagedAssets,
                ocrTextByAssetID: ocrTextByAssetID
            )
            let worker = Task.detached(priority: .userInitiated) {
                CaptureDuplicateDetector.strongestMatch(
                    candidates: input.candidates,
                    records: input.records
                )
            }
            let match = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            if input.revision == (try libraryRevision(patientID: patientID)) {
                return match
            }
            AppLog.data.notice(
                "Duplicate library changed during scan; rebuilding member-scoped snapshot"
            )
        }
        throw CaptureDuplicateDetectionError.libraryChangedRepeatedly
    }

    private func stagedAssets(
        for pages: [M3CapturePageAsset]
    ) throws -> [StagedCaptureAsset] {
        guard !pages.isEmpty else {
            throw CaptureDuplicateDetectionError.invalidCaptureInput
        }
        var expectedBatchByAssetID: [UUID: UUID] = [:]
        for page in pages {
            guard let assetID = page.stagedAssetID,
                  let batchID = page.batchID else {
                throw CaptureDuplicateDetectionError.invalidCaptureInput
            }
            if let existing = expectedBatchByAssetID[assetID],
               existing != batchID {
                throw CaptureDuplicateDetectionError.invalidCaptureInput
            }
            expectedBatchByAssetID[assetID] = batchID
        }
        let batchIDs = Set(expectedBatchByAssetID.values)
        var assetsByID: [UUID: StagedCaptureAsset] = [:]
        for batchID in batchIDs {
            for asset in try vault.journal(batchID: batchID).assets {
                guard expectedBatchByAssetID[asset.id] == batchID else {
                    continue
                }
                guard asset.batchID == batchID else {
                    throw CaptureDuplicateDetectionError.invalidCaptureInput
                }
                assetsByID[asset.id] = asset
            }
        }
        guard Set(assetsByID.keys) == Set(expectedBatchByAssetID.keys) else {
            throw CaptureDuplicateDetectionError.invalidCaptureInput
        }
        var seen = Set<UUID>()
        return try pages
            .sorted { $0.sourceOrder < $1.sourceOrder }
            .compactMap { page in
                guard let id = page.stagedAssetID else {
                    throw CaptureDuplicateDetectionError.invalidCaptureInput
                }
                guard seen.insert(id).inserted else { return nil }
                guard let asset = assetsByID[id] else {
                    throw CaptureDuplicateDetectionError.invalidCaptureInput
                }
                return asset
            }
    }

    private func makeInput(
        patientID: UUID,
        stagedAssets: [StagedCaptureAsset],
        ocrTextByAssetID: [UUID: String]
    ) throws -> (
        candidates: [CaptureDuplicateCandidateSnapshot],
        records: [CaptureDuplicateRecordSnapshot],
        revision: CaptureDuplicateLibraryRevision
    ) {
        let candidates = try stagedAssets.map { asset in
            CaptureDuplicateCandidateSnapshot(
                id: asset.id,
                displayName: asset.displayName,
                sha256: asset.sha256.lowercased(),
                visualURL: try visualURL(
                    kind: asset.kind,
                    preferredPath: asset.previewRelativePath,
                    fallbackPath: asset.originalRelativePath
                ),
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                ocrText: ocrTextByAssetID[asset.id] ?? ""
            )
        }
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\MedicalRecord.eventDate, order: .reverse)]
        )
        descriptor.includePendingChanges = true
        let records = try context.fetch(descriptor).map { record in
            let attachments = try record.attachments.map { attachment in
                CaptureDuplicateAttachmentSnapshot(
                    id: attachment.id,
                    sha256: attachment.sha256.lowercased(),
                    visualURL: try visualURL(
                        kind: attachment.kind,
                        preferredPath: attachment.derivedRelativePath,
                        fallbackPath: attachment.originalRelativePath
                    ),
                    pixelWidth: attachment.pixelWidth,
                    pixelHeight: attachment.pixelHeight
                )
            }
            return CaptureDuplicateRecordSnapshot(
                id: record.id,
                title: record.title,
                eventDate: record.eventDate,
                ocrText: record.ocrText ?? "",
                attachments: attachments
            )
        }
        return (
            candidates,
            records,
            CaptureDuplicateLibraryRevision(
                records: try recordRevisions(patientID: patientID)
            )
        )
    }

    private func libraryRevision(
        patientID: UUID
    ) throws -> CaptureDuplicateLibraryRevision {
        let probeContext = ModelContext(context.container)
        return CaptureDuplicateLibraryRevision(
            records: try recordRevisions(
                patientID: patientID,
                using: probeContext
            )
        )
    }

    private func recordRevisions(
        patientID: UUID,
        using sourceContext: ModelContext? = nil
    ) throws -> [CaptureDuplicateRecordRevision] {
        let sourceContext = sourceContext ?? context
        var descriptor = FetchDescriptor<MedicalRecord>(
            predicate: #Predicate { $0.patientId == patientID },
            sortBy: [SortDescriptor(\MedicalRecord.id)]
        )
        descriptor.includePendingChanges = true
        return try sourceContext.fetch(descriptor).map { record in
            CaptureDuplicateRecordRevision(
                id: record.id,
                updatedAt: record.updatedAt,
                contentRevision: record.contentRevision,
                attachmentSignatures: record.attachments.map {
                    "\($0.id.uuidString):\($0.sha256.lowercased())"
                }.sorted()
            )
        }
    }

    private func visualURL(
        kind: AttachmentKind,
        preferredPath: String?,
        fallbackPath: String
    ) throws -> URL? {
        guard kind == .image else { return nil }
        if let preferredPath {
            let preferredURL = try vault.url(for: preferredPath)
            if FileManager.default.isReadableFile(atPath: preferredURL.path) {
                return preferredURL
            }
        }
        let fallbackURL = try vault.url(for: fallbackPath)
        guard FileManager.default.isReadableFile(atPath: fallbackURL.path) else {
            AppLog.vault.warning(
                "Duplicate scan found no readable visual derivative or original"
            )
            throw CaptureDuplicateDetectionError.invalidCaptureInput
        }
        return fallbackURL
    }
}
