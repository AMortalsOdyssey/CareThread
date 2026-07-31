import Foundation

struct LocalAskIntentRouter {
    private static let metricSignals = [
        "指标", "化验", "检验", "数值", "参考区间", "检查结果"
    ]
    private static let medicationSignals = [
        "吃什么药", "吃了什么药", "用药", "药物", "药什么时候", "开始吃", "停药", "剂量", "在吃什么"
    ]
    private static let followUpSignals = [
        "复查", "下次", "什么时候去", "预约", "随访"
    ]

    func route(_ query: String) -> [LocalAskIntent] {
        let bounded = LocalAskTokenizer().normalizedQuery(query)
        guard !bounded.isEmpty else { return [.freeText] }

        var routed = Set<LocalAskIntent>()
        if containsAny(bounded, Self.metricSignals)
            || !MedicalSynonymLexicon.matches(in: bounded, category: .metric).isEmpty {
            routed.insert(.metric)
        }
        if containsAny(bounded, Self.medicationSignals)
            || !MedicalSynonymLexicon.matches(in: bounded, category: .medication).isEmpty {
            routed.insert(.medication)
        }
        if containsAny(bounded, Self.followUpSignals) {
            routed.insert(.followUp)
        }

        let hasSymptom = !MedicalSynonymLexicon.matches(
            in: bounded,
            category: .colloquial
        ).isEmpty
        if routed.isEmpty || hasSymptom {
            routed.insert(.freeText)
        }

        return LocalAskIntent.allCases.filter(routed.contains)
    }

    private func containsAny(_ source: String, _ candidates: [String]) -> Bool {
        candidates.contains(where: source.contains)
    }
}
