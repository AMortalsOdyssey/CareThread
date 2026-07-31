import Foundation
import Vision

/// Portable representation of a Vision feature print.
///
/// `VNFeaturePrintObservation` has no public data initializer, so archiving the
/// framework object makes persistence depend on private coding details. Store
/// its documented numeric elements instead and compare those directly. Vision
/// currently emits Float or Double elements; both are normalized to Float so
/// the payload is stable across framework object implementations.
struct CaptureVisionFeatureVector: Codable, Equatable, Hashable, Sendable {
    private static let maximumElementCount = 131_072

    let values: [Float]

    init?(values: [Float]) {
        guard !values.isEmpty,
              values.count <= Self.maximumElementCount,
              values.allSatisfy(\.isFinite) else {
            return nil
        }
        self.values = values
    }

    init?(observation: VNFeaturePrintObservation) {
        let count = observation.elementCount
        guard count > 0, count <= Self.maximumElementCount else { return nil }
        switch observation.elementType {
        case .float:
            guard observation.data.count == count * MemoryLayout<Float>.size
            else { return nil }
            var decoded = [Float](repeating: 0, count: count)
            let copied = decoded.withUnsafeMutableBytes {
                observation.data.copyBytes(to: $0)
            }
            guard copied == observation.data.count,
                  decoded.allSatisfy(\.isFinite) else {
                return nil
            }
            values = decoded
        case .double:
            guard observation.data.count == count * MemoryLayout<Double>.size
            else { return nil }
            var decoded = [Double](repeating: 0, count: count)
            let copied = decoded.withUnsafeMutableBytes {
                observation.data.copyBytes(to: $0)
            }
            guard copied == observation.data.count,
                  decoded.allSatisfy(\.isFinite) else {
                return nil
            }
            let normalized = decoded.map(Float.init)
            guard normalized.allSatisfy(\.isFinite) else { return nil }
            values = normalized
        default:
            return nil
        }
    }

    func euclideanDistance(to other: CaptureVisionFeatureVector) -> Float? {
        guard values.count == other.values.count else { return nil }
        var squaredDistance = 0.0
        for (lhs, rhs) in zip(values, other.values) {
            let delta = Double(lhs) - Double(rhs)
            squaredDistance += delta * delta
        }
        let result = squaredDistance.squareRoot()
        guard result.isFinite, result <= Double(Float.greatestFiniteMagnitude)
        else { return nil }
        return Float(result)
    }
}

/// Versioned, rebuildable data derived from one attachment's immutable bytes.
///
/// The payloads never become a second source of truth: the protected original
/// remains authoritative, while each algorithm version can be rebuilt lazily.
/// Keeping the text slot beside the visual fingerprints lets local search reuse
/// the same lifecycle in the Ask feature without coupling this layer to either
/// consumer.
struct CaptureAttachmentDerivedArtifactSet: Codable, Equatable, Hashable, Sendable {
    let sourceSHA256: String?
    let perceptualHashPayload: Data?
    let perceptualHashAlgorithmVersion: String?
    let visionFeaturePrintPayload: Data?
    let visionFeaturePrintAlgorithmVersion: String?

    init(
        sourceSHA256: String? = nil,
        perceptualHashPayload: Data?,
        perceptualHashAlgorithmVersion: String?,
        visionFeaturePrintPayload: Data?,
        visionFeaturePrintAlgorithmVersion: String?
    ) {
        self.sourceSHA256 = sourceSHA256?.lowercased()
        self.perceptualHashPayload = perceptualHashPayload
        self.perceptualHashAlgorithmVersion = perceptualHashAlgorithmVersion
        self.visionFeaturePrintPayload = visionFeaturePrintPayload
        self.visionFeaturePrintAlgorithmVersion =
            visionFeaturePrintAlgorithmVersion
    }

    static let legacyMissing = CaptureAttachmentDerivedArtifactSet(
        perceptualHashPayload: nil,
        perceptualHashAlgorithmVersion: nil,
        visionFeaturePrintPayload: nil,
        visionFeaturePrintAlgorithmVersion: nil
    )

    func hasCurrentPerceptualHash(sourceSHA256: String) -> Bool {
        self.sourceSHA256 == sourceSHA256.lowercased()
            && hasCurrentPerceptualHashVersion
    }

    func hasCurrentVisionFeaturePrint(sourceSHA256: String) -> Bool {
        self.sourceSHA256 == sourceSHA256.lowercased()
            && hasCurrentVisionFeaturePrintVersion
    }

    var hasCurrentPerceptualHashVersion: Bool {
        guard perceptualHashAlgorithmVersion
                == CapturePerceptualImageHash.algorithmIdentifier else {
            return false
        }
        // Current version + nil is an explicit "attempted but unavailable"
        // marker. Non-nil malformed bytes are corruption and must be rebuilt.
        guard let payload = perceptualHashPayload else { return true }
        guard
              (32...8_192).contains(payload.count),
              let value = CaptureAttachmentDerivedArtifactCodec
                .decodePerceptualHash(payload) else {
            return false
        }
        return (1...4).contains(value.dctHashes.count)
            && (1...16).contains(value.blockHashes.count)
            && (1...16).contains(value.differenceHashes.count)
    }

    var hasCurrentVisionFeaturePrintVersion: Bool {
        guard visionFeaturePrintAlgorithmVersion
                == CaptureVisionImageFingerprint.algorithmIdentifier else {
            return false
        }
        guard let payload = visionFeaturePrintPayload else { return true }
        guard
              (64...1_048_576).contains(payload.count) else {
            return false
        }
        return CaptureAttachmentDerivedArtifactCodec.decodeVisionFeaturePrint(
            payload
        ) != nil
    }
}

struct CaptureAttachmentDerivedArtifactComputer: Sendable {
    var makePerceptualHash: @Sendable (URL) -> CapturePerceptualHashValue?
    var makeVisionFeaturePrint: @Sendable (URL) -> CaptureVisionFeatureVector?

    static let live = CaptureAttachmentDerivedArtifactComputer(
        makePerceptualHash: { CapturePerceptualImageHash.make(url: $0) },
        makeVisionFeaturePrint: { CaptureVisionImageFingerprint.make(url: $0) }
    )

    func makeAll(
        url: URL,
        sourceSHA256: String
    ) -> CaptureAttachmentDerivedArtifactSet {
        let perceptualHash = makePerceptualHash(url)
        let featurePrint = makeVisionFeaturePrint(url)
        return CaptureAttachmentDerivedArtifactSet(
            sourceSHA256: sourceSHA256,
            perceptualHashPayload: perceptualHash.flatMap(
                CaptureAttachmentDerivedArtifactCodec.encodePerceptualHash
            ),
            perceptualHashAlgorithmVersion:
                CapturePerceptualImageHash.algorithmIdentifier,
            visionFeaturePrintPayload: featurePrint.flatMap(
                CaptureAttachmentDerivedArtifactCodec.encodeVisionFeaturePrint
            ),
            visionFeaturePrintAlgorithmVersion:
                CaptureVisionImageFingerprint.algorithmIdentifier
        )
    }

    func refreshing(
        _ stored: CaptureAttachmentDerivedArtifactSet,
        url: URL,
        sourceSHA256: String,
        includeVision: Bool
    ) -> CaptureAttachmentDerivedArtifactSet {
        let perceptualHashPayload: Data?
        let perceptualHashVersion: String?
        if stored.hasCurrentPerceptualHash(sourceSHA256: sourceSHA256) {
            perceptualHashPayload = stored.perceptualHashPayload
            perceptualHashVersion = stored.perceptualHashAlgorithmVersion
        } else {
            perceptualHashPayload = makePerceptualHash(url).flatMap(
                CaptureAttachmentDerivedArtifactCodec.encodePerceptualHash
            )
            perceptualHashVersion = CapturePerceptualImageHash.algorithmIdentifier
        }

        let visionPayload: Data?
        let visionVersion: String?
        if stored.hasCurrentVisionFeaturePrint(sourceSHA256: sourceSHA256)
            || !includeVision {
            visionPayload = stored.visionFeaturePrintPayload
            visionVersion = stored.visionFeaturePrintAlgorithmVersion
        } else {
            visionPayload = makeVisionFeaturePrint(url).flatMap(
                CaptureAttachmentDerivedArtifactCodec.encodeVisionFeaturePrint
            )
            visionVersion = CaptureVisionImageFingerprint.algorithmIdentifier
        }
        return CaptureAttachmentDerivedArtifactSet(
            sourceSHA256: sourceSHA256,
            perceptualHashPayload: perceptualHashPayload,
            perceptualHashAlgorithmVersion: perceptualHashVersion,
            visionFeaturePrintPayload: visionPayload,
            visionFeaturePrintAlgorithmVersion: visionVersion
        )
    }
}

enum CaptureAttachmentDerivedArtifactCodec {
    static func encodePerceptualHash(
        _ value: CapturePerceptualHashValue
    ) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decodePerceptualHash(
        _ data: Data?
    ) -> CapturePerceptualHashValue? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(
            CapturePerceptualHashValue.self,
            from: data
        )
    }

    static func encodeVisionFeaturePrint(
        _ value: CaptureVisionFeatureVector
    ) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decodeVisionFeaturePrint(
        _ data: Data?
    ) -> CaptureVisionFeatureVector? {
        guard let data else { return nil }
        guard let value = try? JSONDecoder().decode(
            CaptureVisionFeatureVector.self,
            from: data
        ) else {
            return nil
        }
        return CaptureVisionFeatureVector(values: value.values)
    }
}
