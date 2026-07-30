import Foundation

enum ModelPayloadError: Error, Equatable {
    case encodingFailed
}

enum ModelPayloadStatus: Equatable {
    case empty
    case valid(version: Int)
    case legacyUnversioned
    case unknownVersion(Int)
    case corrupted
}

enum ModelPayloadRead<Value> {
    case value(Value, status: ModelPayloadStatus)
    case unavailable(status: ModelPayloadStatus, originalData: Data)

    var value: Value? {
        guard case let .value(value, _) = self else { return nil }
        return value
    }

    var status: ModelPayloadStatus {
        switch self {
        case let .value(_, status), let .unavailable(status, _):
            return status
        }
    }

    var originalData: Data? {
        guard case let .unavailable(_, originalData) = self else { return nil }
        return originalData
    }
}

enum ModelPayload {
    static let currentSchemaVersion = 1

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func encode<Value: Codable>(_ value: Value) throws -> Data {
        do {
            return try makeEncoder().encode(
                PayloadEnvelope(schemaVersion: currentSchemaVersion, value: value)
            )
        } catch {
            throw ModelPayloadError.encodingFailed
        }
    }

    /// Model initializers use only known Foundation value types. A failure is a
    /// programmer/schema error and must never silently become an empty payload.
    static func requiredEncode<Value: Codable>(_ value: Value) -> Data {
        do {
            return try encode(value)
        } catch {
            preconditionFailure("CareThread model payload encoding failed")
        }
    }

    static func requiredEncodeOptional<Value: Codable>(_ value: Value?) -> Data {
        guard let value else { return Data() }
        return requiredEncode(value)
    }

    static func read<Value: Codable>(
        _ type: Value.Type,
        from data: Data
    ) -> ModelPayloadRead<Value> {
        guard !data.isEmpty else {
            return .unavailable(status: .empty, originalData: data)
        }

        let decoder = makeDecoder()
        if let metadata = try? decoder.decode(PayloadEnvelopeMetadata.self, from: data) {
            guard metadata.schemaVersion == currentSchemaVersion else {
                return .unavailable(
                    status: .unknownVersion(metadata.schemaVersion),
                    originalData: data
                )
            }
            do {
                let envelope = try decoder.decode(PayloadEnvelope<Value>.self, from: data)
                return .value(envelope.value, status: .valid(version: metadata.schemaVersion))
            } catch {
                return .unavailable(status: .corrupted, originalData: data)
            }
        }

        do {
            return .value(
                try decoder.decode(type, from: data),
                status: .legacyUnversioned
            )
        } catch {
            return .unavailable(status: .corrupted, originalData: data)
        }
    }

    static func decode<Value: Codable>(
        _ type: Value.Type,
        from data: Data,
        fallback: Value
    ) -> Value {
        read(type, from: data).value ?? fallback
    }

    static func decodeOptional<Value: Codable>(_ type: Value.Type, from data: Data) -> Value? {
        read(type, from: data).value
    }
}

private struct PayloadEnvelope<Value: Codable>: Codable {
    var schemaVersion: Int
    var value: Value
}

private struct PayloadEnvelopeMetadata: Decodable {
    var schemaVersion: Int
}

enum MemberIdentity {
    static func normalizedDisplayName(_ value: String) -> String {
        optionalTrimmed(value) ?? "未命名成员"
    }

    static func optionalTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedOptional(_ value: String?) -> String? {
        guard let value = optionalTrimmed(value) else { return nil }
        let result = normalize(value)
        return result.isEmpty ? nil : result
    }

    static func normalize(_ value: String) -> String {
        let folded = value
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_Hans_CN")
            )
            .lowercased()
        return folded.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// OCR assignment evidence intentionally excludes the private display
    /// label ("妈妈", "爸爸"). Only report name and explicit aliases count.
    static func normalizedEvidenceAliases(
        reportName: String?,
        aliases: [String]
    ) -> [String] {
        var seen = Set<String>()
        return ([reportName].compactMap { optionalTrimmed($0) } + aliases.compactMap(optionalTrimmed))
            .map(normalize)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func searchText(displayName: String, evidenceAliases: [String]) -> String {
        let all = [normalize(displayName)] + evidenceAliases
        return all.filter { !$0.isEmpty }.map { "|\($0)|" }.joined()
    }
}
