import Foundation
import NaturalLanguage

struct LocalAskTokenizer: Sendable {
    static let maximumQueryLength = 200

    private static let stopTerms: Set<String> = [
        "什么", "时候", "怎么", "怎么样", "有没有", "之前", "记录", "资料", "查看",
        "去年", "今年", "上个月", "最近", "三个", "三个月", "三年前", "一次", "第一",
        "的", "了", "我", "在", "去", "过", "哪些", "结果", "显示", "查找"
    ]

    func normalizedQuery(_ source: String) -> String {
        String(source.prefix(Self.maximumQueryLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func terms(in source: String, isQuery: Bool = false) -> [String] {
        let bounded = isQuery ? normalizedQuery(source) : source
        guard !bounded.isEmpty else { return [] }

        var terms: [String] = []
        terms.reserveCapacity(min(256, bounded.count * 2))

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = bounded
        tokenizer.enumerateTokens(in: bounded.startIndex..<bounded.endIndex) { range, _ in
            appendNormalized(String(bounded[range]), to: &terms)
            return true
        }

        appendCharacterNGrams(from: bounded, to: &terms)
        terms.append(contentsOf: MedicalSynonymLexicon.markers(in: bounded))

        return terms.filter { term in
            !term.isEmpty && !Self.stopTerms.contains(term)
        }
    }

    private func appendNormalized(_ source: String, to terms: inout [String]) {
        let normalized = MedicalSynonymLexicon.normalizeForMatching(source)
        guard !normalized.isEmpty else { return }
        terms.append(normalized)
    }

    private func appendCharacterNGrams(from source: String, to terms: inout [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"[\u{4E00}-\u{9FFF}]+"#) else {
            return
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: range) {
            guard let swiftRange = Range(match.range, in: source) else { continue }
            let characters = Array(source[swiftRange]).map(String.init)
            guard !characters.isEmpty else { continue }
            if characters.count <= 8 {
                terms.append(characters.joined())
            }
            if characters.count >= 2 {
                for index in 0..<(characters.count - 1) {
                    terms.append(characters[index] + characters[index + 1])
                }
            }
        }
    }
}
