import Foundation

extension Copy {
    enum Timeline {
        static let navigationTitle = "时间线"
        static let filterAll = "全部"
        static let filterAbnormal = "仅异常"
        static let filterRecords = "报告"
        static let filterMedications = "用药"
        static let filterFollowUps = "复查"
        static let empty = "录入第一份资料后，你的病程线会从这里开始。"
        static let emptyFiltered = "这个筛选下还没有事件。"
        static let loadFailed = "时间线暂时无法载入，请稍后重试。"
        static let loadMore = "加载更多"
        static let returnToLatest = "回到最新"
        static let openDetail = "打开对应详情"
        static let abnormal = "异常"
        static let overdue = "已过期"
        static let medicationStarted = "开始用药"
        static let medicationAdjusted = "用药调整"
        static let medicationStopped = "停止用药"
        static let medicalOrderCreated = "新增医嘱"
        static let followUpDue = "复查安排"
        static let followUpOverdue = "复查已过期"
        static let followUpCompleted = "完成复查"
        static let doseNotRecorded = "剂量未记录"

        static func adjustmentDetail(
            name: String,
            from: String,
            to: String
        ) -> String {
            "\(name) \(from) → \(to)"
        }

        static func medicationDetail(
            name: String,
            dose: String
        ) -> String {
            "\(name) · \(dose)"
        }

        static func items(_ values: [String]) -> String {
            values.joined(separator: "、")
        }

        static func dayAndType(
            day: String,
            type: String
        ) -> String {
            "\(day) 日 · \(type)"
        }

        static func eventType(_ kind: TimelineEvent.Kind) -> String {
            switch kind {
            case .medicalRecord: filterRecords
            case .medicationStarted: medicationStarted
            case .medicationAdjusted: medicationAdjusted
            case .medicationStopped: medicationStopped
            case .medicalOrder: medicalOrderCreated
            case .followUpDue: followUpDue
            case .followUpCompleted: followUpCompleted
            }
        }
    }
}

extension TimelineFilter {
    var title: String {
        switch self {
        case .all: Copy.Timeline.filterAll
        case .abnormal: Copy.Timeline.filterAbnormal
        case .records: Copy.Timeline.filterRecords
        case .medications: Copy.Timeline.filterMedications
        case .followUps: Copy.Timeline.filterFollowUps
        }
    }
}
