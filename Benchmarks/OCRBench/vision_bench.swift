import AppKit
import Darwin
import Foundation
import ImageIO
import Vision

struct Sample {
    let id: String
    let imageURL: URL
    let group: String
    let subgroup: String
    let scored: Bool
}

struct Recognition {
    let text: String
    let confidence: Double
}

enum BenchError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidManifest
    case imageLoadFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            "usage: vision_bench <testset-directory> <output-json> [iterations]"
        case .invalidManifest:
            "manifest.json is invalid"
        case .imageLoadFailed(let path):
            "could not decode image at \(path)"
        }
    }
}

func recognize(_ imageURL: URL) throws -> Recognition {
    guard
        let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw BenchError.imageLoadFailed(imageURL.path)
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])

    let blocks = (request.results ?? []).compactMap { observation -> (String, CGRect, Float)? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return (candidate.string, observation.boundingBox, candidate.confidence)
    }
    .sorted { lhs, rhs in
        if abs(lhs.1.maxY - rhs.1.maxY) > 0.01 {
            return lhs.1.maxY > rhs.1.maxY
        }
        return lhs.1.minX < rhs.1.minX
    }
    let confidence = blocks.isEmpty
        ? 0
        : blocks.reduce(0.0) { $0 + Double($1.2) } / Double(blocks.count)
    return Recognition(text: blocks.map(\.0).joined(separator: "\n"), confidence: confidence)
}

func loadSamples(testset: URL) throws -> [Sample] {
    let data = try Data(contentsOf: testset.appendingPathComponent("manifest.json"))
    guard
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rows = root["samples"] as? [[String: Any]]
    else {
        throw BenchError.invalidManifest
    }
    return try rows.map { row in
        guard
            let id = row["id"] as? String,
            let image = row["image"] as? String,
            let group = row["group"] as? String,
            let subgroup = row["subgroup"] as? String,
            let scored = row["scored"] as? Bool
        else {
            throw BenchError.invalidManifest
        }
        return Sample(
            id: id,
            imageURL: testset.appendingPathComponent(image),
            group: group,
            subgroup: subgroup,
            scored: scored
        )
    }
}

func peakResidentBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Int64(usage.ru_maxrss)
}

@main
struct VisionBench {
    static func main() {
        do {
            try run()
        } catch {
            let nsError = error as NSError
            FileHandle.standardError.write(
                Data("vision benchmark failed: \(nsError.domain) \(nsError.code) \(nsError)\n".utf8)
            )
            exit(1)
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count >= 3 else { throw BenchError.invalidArguments }
        let languages = try VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequestRevision3
        )
        FileHandle.standardError.write(Data("vision languages: \(languages)\n".utf8))
        let testset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let iterations = max(1, Int(CommandLine.arguments.dropFirst(3).first ?? "3") ?? 3)
        let samples = try loadSamples(testset: testset)
        guard let warmup = samples.first else { throw BenchError.invalidManifest }

        _ = try recognize(warmup.imageURL)
        let baselineRSS = peakResidentBytes()

        var rows: [[String: Any]] = []
        for sample in samples {
            var recognition: Recognition?
            var timings: [Double] = []
            for _ in 0..<iterations {
                let started = DispatchTime.now().uptimeNanoseconds
                let current = try recognize(sample.imageURL)
                let ended = DispatchTime.now().uptimeNanoseconds
                timings.append(Double(ended - started) / 1_000_000)
                recognition = current
            }
            guard let recognition else { continue }
            rows.append([
                "id": sample.id,
                "group": sample.group,
                "subgroup": sample.subgroup,
                "scored": sample.scored,
                "text": recognition.text,
                "average_confidence": recognition.confidence,
                "latency_ms": timings,
            ])
            FileHandle.standardError.write(Data("vision: \(sample.id)\n".utf8))
        }

        let result: [String: Any] = [
            "engine": "Apple Vision",
            "engine_identifier": "apple-vision",
            "platform": "macOS Apple Silicon",
            "iterations_per_page": iterations,
            "model_bytes": 0,
            "runtime_arm64_dylib_bytes": 0,
            "estimated_arm64_increment_bytes": 0,
            "baseline_rss_bytes": baselineRSS,
            "peak_rss_bytes": peakResidentBytes(),
            "peak_rss_increment_bytes": max(0, peakResidentBytes() - baselineRSS),
            "rows": rows,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: output, options: .atomic)
        print(output.path)
    }
}
