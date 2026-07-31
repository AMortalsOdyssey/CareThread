import Foundation

enum ScoreError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidJSON(String)

    var description: String {
        switch self {
        case .invalidArguments:
            "usage: extraction_score <manifest-json> <engine-json> <output-json>"
        case .invalidJSON(let path):
            "invalid JSON: \(path)"
        }
    }
}

func jsonDictionary(at path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ScoreError.invalidJSON(path)
    }
    return dictionary
}

func indicatorHit(expected: String, extraction: ExtractionResult) -> Bool {
    if let numeric = Double(expected) {
        if extraction.labItems.contains(where: { abs($0.value - numeric) < 0.0001 }) {
            return true
        }
        return extraction.medicationHints.contains {
            guard let value = $0.doseValue else { return false }
            return abs(value - numeric) < 0.0001
        }
    }
    return extraction.summary.localizedCaseInsensitiveContains(expected)
        || extraction.abnormalFlags.contains {
            $0.localizedCaseInsensitiveContains(expected)
        }
}

@main
struct ExtractionScore {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("extraction scoring failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 4 else { throw ScoreError.invalidArguments }
        let manifestPath = CommandLine.arguments[1]
        let enginePath = CommandLine.arguments[2]
        let outputPath = CommandLine.arguments[3]
        let manifest = try jsonDictionary(at: manifestPath)
        var engine = try jsonDictionary(at: enginePath)
        guard
            let samples = manifest["samples"] as? [[String: Any]],
            let inputRows = engine["rows"] as? [[String: Any]]
        else {
            throw ScoreError.invalidJSON(manifestPath)
        }

        let expectedByID: [String: [String: Any]] = Dictionary(
            uniqueKeysWithValues: samples.compactMap { sample in
                guard
                    let id = sample["id"] as? String,
                    let expected = sample["expected"] as? [String: Any]
                else {
                    return nil
                }
                return (id, expected)
            }
        )

        let extractor = ExtractionEngine()
        let today = CTDate.make(2026, 7, 30)
        let identifier = engine["engine_identifier"] as? String ?? "benchmark"
        let rows: [[String: Any]] = inputRows.map { input in
            guard
                let id = input["id"] as? String,
                let text = input["text"] as? String
            else {
                return input
            }
            var output = input
            let extraction = extractor.extract(text, today: today, engineIdentifier: identifier)
            let expected = expectedByID[id] ?? [:]
            let expectedDate = expected["date"] as? String
            let expectedHospital = expected["hospital"] as? String
            let expectedType = expected["type"] as? String
            let expectedIndicator = expected["indicator"] as? String

            let date = extraction.eventDate.map { CTDateFormatter.iso.string(from: $0) }
            let expectedFieldCount = [
                expectedDate,
                expectedHospital,
                expectedType,
                expectedIndicator,
            ].compactMap { $0 }.count
            let hits: [String: Bool] = [
                "date": expectedDate.map { $0 == date } ?? false,
                "hospital": expectedHospital.map { $0 == extraction.hospital } ?? false,
                "type": expectedType.map { $0 == extraction.type.rawValue } ?? false,
                "indicator": expectedIndicator.map {
                    indicatorHit(expected: $0, extraction: extraction)
                } ?? false,
            ]
            output["field_hits"] = hits
            output["field_hit_count"] = hits.values.filter { $0 }.count
            output["field_total_count"] = expectedFieldCount
            output["extraction"] = [
                "type": extraction.type.rawValue,
                "date": date as Any,
                "hospital": extraction.hospital as Any,
                "department": extraction.department as Any,
                "title": extraction.title,
                "summary": extraction.summary,
                "lab_values": extraction.labItems.map(\.value),
                "medication_doses": extraction.medicationHints.compactMap(\.doseValue),
            ]
            return output
        }
        engine["rows"] = rows
        engine["extraction_engine_source"] =
            "CareThread/Core/Services/ExtractionEngine/ExtractionEngine.swift"
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: engine,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: outputURL, options: .atomic)
        print(outputPath)
    }
}
