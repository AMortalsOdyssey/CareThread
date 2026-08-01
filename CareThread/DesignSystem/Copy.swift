enum Copy {
    static let disclaimer = "CareThread 只帮你整理和回看自己的就医资料，不提供诊断、治疗或用药建议。所有医疗决定请以医生意见为准。"
    static let pdfDisclaimer = "本摘要由患者自行整理生成，仅供就诊沟通参考 · 由 CareThread 整理"
    static let ocrEmpty = "没认出文字。可以换张更清晰的照片，或直接手动填写。"
    static let futureDate = "这个日期晚于今天，请核对一下。"
    static let exportNotice = "备份包里是你的全部记录和原件，请保管好：拿到这个文件的人可以看到其中内容。"
    static let viewOriginal = "查看原文"

    enum Tab {
        static let home = "首页"
        static let timeline = "时间线"
        static let capture = "录入"
        static let records = "记录"
        static let manage = "管理"
    }

    enum Elder {
        static let today = "今天"
        static let capture = "拍照存报告"
        static let noMedication = "还没有记录用药，请家人帮忙添加。"
        static let pendingReview = "有 %d 份新存的报告，等家人帮忙核对"
        static let captureDescription = "拍下报告单，存进手机里"
        static let typeQuestion = "这是什么？"
        static let dateQuestion = "哪天的？"
        static let saved = "存好了 ✓"
        static let ocrEmpty = "照片存好了，字没认出来，家人可以补。"
        static let recordPending = "等家人核对"
        static let doctorHeader = "把这一页拿给医生看"
        static let switchToElderTitle = "切换到长辈版？"
        static let switchToElderBody = "字更大、操作更简单，资料完全一样，随时可以换回来。"
        static let switchToElderAction = "切换"
        static let switchToStandardTitle = "换回标准版？"
        static let switchToStandardBody = "功能更全，适合帮忙整理资料的家人。"
        static let switchToStandardAction = "换回"
        static let notNow = "先不用"
    }

    enum Recovery {
        static let progress = "正在安全恢复本地资料…"
        static let title = "资料库保护模式"
        static let referenceCode = "诊断编号"
        static let vaultFailure =
            "原件事务尚未安全完成。CareThread 没有删除资料，请重新打开应用重试；若仍失败，请保留此编号联系支持。"
    }
}
