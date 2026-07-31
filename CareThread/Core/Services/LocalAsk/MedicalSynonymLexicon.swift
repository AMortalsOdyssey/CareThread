import Foundation

enum MedicalSynonymCategory: String, Codable, CaseIterable {
    case medication
    case metric
    case colloquial
}

struct MedicalSynonymEntry: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var category: MedicalSynonymCategory
    var canonical: String
    var aliases: [String]

    var allTerms: [String] {
        [canonical] + aliases
    }

    var marker: String {
        "ctsyn_\(category.rawValue)_\(id)"
    }
}

enum MedicalSynonymLexicon {
    /// This list is intentionally independent from search code. Adding a row
    /// automatically participates in query routing, indexing and regression QA.
    static let entries: [MedicalSynonymEntry] = [
        .init(id: "levothyroxine", category: .medication, canonical: "左甲状腺素钠片", aliases: ["优甲乐", "左甲状腺素", "甲状腺素片"]),
        .init(id: "acarbose", category: .medication, canonical: "阿卡波糖", aliases: ["拜糖平"]),
        .init(id: "metformin", category: .medication, canonical: "二甲双胍", aliases: ["格华止", "二甲双胍缓释片"]),
        .init(id: "aspirin", category: .medication, canonical: "阿司匹林", aliases: ["拜阿司匹灵", "阿司匹林肠溶片"]),
        .init(id: "atorvastatin", category: .medication, canonical: "阿托伐他汀钙片", aliases: ["立普妥", "阿托伐他汀"]),
        .init(id: "amlodipine", category: .medication, canonical: "氨氯地平", aliases: ["络活喜", "苯磺酸氨氯地平"]),
        .init(id: "ibuprofen", category: .medication, canonical: "布洛芬", aliases: ["芬必", "布洛芬缓释胶囊"]),
        .init(id: "omeprazole", category: .medication, canonical: "奥美拉唑", aliases: ["洛赛克", "奥美拉唑肠溶胶囊"]),

        .init(id: "tsh", category: .metric, canonical: "促甲状腺激素", aliases: ["TSH", "促甲状腺素"]),
        .init(id: "ft4", category: .metric, canonical: "游离甲状腺素", aliases: ["FT4", "游离T4"]),
        .init(id: "ft3", category: .metric, canonical: "游离三碘甲状腺原氨酸", aliases: ["FT3", "游离T3"]),
        .init(id: "hemoglobin", category: .metric, canonical: "血红蛋白", aliases: ["Hb", "HGB"]),
        .init(id: "wbc", category: .metric, canonical: "白细胞计数", aliases: ["WBC", "白细胞"]),
        .init(id: "glucose", category: .metric, canonical: "血糖", aliases: ["GLU", "空腹血糖", "葡萄糖"]),
        .init(id: "blood_pressure", category: .metric, canonical: "血压", aliases: ["BP", "收缩压", "舒张压"]),
        .init(id: "cholesterol", category: .metric, canonical: "总胆固醇", aliases: ["TC", "胆固醇"]),

        .init(id: "headache", category: .colloquial, canonical: "头痛", aliases: ["头疼"]),
        .init(id: "diarrhea", category: .colloquial, canonical: "腹泻", aliases: ["拉肚子"]),
        .init(id: "dyspnea", category: .colloquial, canonical: "呼吸困难", aliases: ["喘不上气", "气短"]),
        .init(id: "palpitation", category: .colloquial, canonical: "心悸", aliases: ["心慌"]),
        .init(id: "abdominal_pain", category: .colloquial, canonical: "腹痛", aliases: ["肚子疼"]),
        .init(id: "fever", category: .colloquial, canonical: "发热", aliases: ["发烧"]),
        .init(id: "edema", category: .colloquial, canonical: "下肢水肿", aliases: ["腿肿"]),
        .init(id: "fatigue", category: .colloquial, canonical: "乏力", aliases: ["没劲"])
    ]

    static func entries(in category: MedicalSynonymCategory) -> [MedicalSynonymEntry] {
        entries.filter { $0.category == category }
    }

    static func matches(
        in source: String,
        category: MedicalSynonymCategory? = nil
    ) -> [MedicalSynonymEntry] {
        let normalized = normalizeForMatching(source)
        guard !normalized.isEmpty else { return [] }
        return entries.filter { entry in
            (category == nil || entry.category == category)
                && entry.allTerms.contains { normalized.contains(normalizeForMatching($0)) }
        }
    }

    static func markers(in source: String) -> [String] {
        matches(in: source).map(\.marker)
    }

    static func displayTerm(for marker: String) -> String {
        entries.first(where: { $0.marker == marker })?.canonical ?? marker
    }

    static func normalizeForMatching(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_Hans_CN")
            )
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
