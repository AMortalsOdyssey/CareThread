import Foundation
import UIKit
import XCTest
@testable import CareThread

final class OCRSimulatorBenchmarkTests: XCTestCase {
    func testAppleVisionProtocolLatency() async throws {
        let bundle = Bundle(for: Self.self)
        let manifestURL = try XCTUnwrap(
            bundle.url(forResource: "manifest", withExtension: "json")
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        let samples = try XCTUnwrap(root["samples"] as? [[String: Any]])
            .filter { ($0["scored"] as? Bool) == true }
        let engine = VisionOCREngine()

        let firstName = try imageBaseName(samples[0])
        _ = try await engine.recognize(try image(named: firstName, bundle: bundle))

        var latencies: [Double] = []
        for sample in samples {
            let name = try imageBaseName(sample)
            let input = try image(named: name, bundle: bundle)
            for _ in 0..<3 {
                let started = ContinuousClock.now
                _ = try await engine.recognize(input)
                let elapsed = started.duration(to: .now)
                latencies.append(
                    Double(elapsed.components.seconds) * 1_000
                        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                )
            }
        }
        let ordered = latencies.sorted()
        let p95Index = max(0, Int(ceil(0.95 * Double(ordered.count))) - 1)
        let p95 = ordered[p95Index]
        let mean = ordered.reduce(0, +) / Double(ordered.count)
        let marker = [
            "engine": "Apple Vision",
            "platform": "iPhone 16 Simulator iOS 18.6",
            "pages": samples.count,
            "iterations_per_page": 3,
            "p95_latency_ms": p95,
            "mean_latency_ms": mean,
        ] as [String: Any]
        let markerData = try JSONSerialization.data(
            withJSONObject: marker,
            options: [.sortedKeys]
        )
        let attachment = XCTAttachment(
            data: markerData,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "vision_simulator_metrics.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(
            "OCR_BENCH_SIMULATOR_JSON="
                + String(decoding: markerData, as: UTF8.self)
        )
        XCTAssertLessThan(p95, 2_000)
    }

    private func imageBaseName(_ sample: [String: Any]) throws -> String {
        let path = try XCTUnwrap(sample["image"] as? String)
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func image(named name: String, bundle: Bundle) throws -> UIImage {
        let url = bundle.url(forResource: name, withExtension: "png")
            ?? bundle.url(forResource: name, withExtension: "jpg")
        let resolvedURL = try XCTUnwrap(url)
        return try XCTUnwrap(UIImage(data: Data(contentsOf: resolvedURL)))
    }
}
