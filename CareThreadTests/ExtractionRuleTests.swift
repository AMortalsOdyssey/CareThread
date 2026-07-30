import Foundation
import Testing
@testable import CareThread

struct ExtractionRuleTests {
    private let engine = ExtractionEngine()
    private let today = CTDate.make(2026, 7, 30)

    @Test("短横线日期可解析")
    func test_date_whenHyphenated_parses() {
        let result = engine.extract("检查日期：2026-03-15\nCT 检查报告", today: today)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
    }

    @Test("中文日期可解析")
    func test_date_whenChineseCharacters_parses() {
        let result = engine.extract("检查日期：2026年3月15日\nCT 检查报告", today: today)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
    }

    @Test("斜杠日期可解析")
    func test_date_whenSlashSeparated_parses() {
        let result = engine.extract("检查日期：2026/3/15\nCT 检查报告", today: today)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
    }

    @Test("出院日期优先于入院日期")
    func test_date_whenAdmissionAndDischarge_usesDischarge() {
        let text = "入院日期：2024-08-23 出院日期：2024-09-02\n出院小结"
        let result = engine.extract(text, today: today)
        #expect(result.eventDate == CTDate.make(2024, 9, 2))
    }

    @Test("上下文日期优先于文首日期")
    func test_date_whenHeaderHasOtherDate_usesContextDate() {
        let text = "打印日期 2026-03-20\n检查日期：2026-03-15\nCT 检查报告"
        let result = engine.extract(text, today: today)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
    }

    @Test("无效日期被丢弃")
    func test_date_whenInvalid_returnsNil() {
        let result = engine.extract("检查日期：2026-02-30\nCT 检查报告", today: today)
        #expect(result.eventDate == nil)
    }

    @Test("未来日期保留但标低置信")
    func test_date_whenFuture_keepsWithLowConfidence() {
        let result = engine.extract("检查日期：2027-01-01\nCT 检查报告", today: today)
        #expect(result.eventDate == CTDate.make(2027, 1, 1))
        #expect(result.eventDateConfidence == .low)
    }

    @Test("无日期文本返回空日期")
    func test_date_whenMissing_returnsNil() {
        let result = engine.extract("四川大学华西医院 门诊病历", today: today)
        #expect(result.eventDate == nil)
    }

    @Test("医院正则取完整长名称")
    func test_hospital_whenLongName_returnsFullMatch() {
        let result = engine.extract("四川大学华西医院 检验报告 参考区间", today: today)
        #expect(result.hospital == "四川大学华西医院")
    }

    @Test("人民医院名称可识别")
    func test_hospital_whenMunicipalHospital_returnsMatch() {
        let result = engine.extract("成都市第三人民医院 CT检查报告", today: today)
        #expect(result.hospital == "成都市第三人民医院")
    }

    @Test("无医院文本返回 nil")
    func test_hospital_whenMissing_returnsNil() {
        let result = engine.extract("个人记录 门诊病历", today: today)
        #expect(result.hospital == nil)
    }

    @Test("送检科室优先于正文其他科室")
    func test_department_whenSpecimenDepartmentPresent_prefersIt() {
        let text = "内分泌科会诊\n送检科室：甲状腺外科\n病理诊断"
        let result = engine.extract(text, today: today)
        #expect(result.department == "甲状腺外科")
    }

    @Test("申请科室可识别")
    func test_department_whenRequestDepartmentPresent_returnsIt() {
        let result = engine.extract("申请科室：内分泌科\n超声检查所见", today: today)
        #expect(result.department == "内分泌科")
    }

    @Test("词表外相似科室不误配")
    func test_department_whenUnknown_returnsNil() {
        let result = engine.extract("科室：火星研究部\n门诊病历", today: today)
        #expect(result.department == nil)
    }

    @Test("检验强证据判为检验")
    func test_type_whenLabEvidence_returnsLab() {
        let result = engine.extract("检验报告\n结果 单位 参考区间", today: today)
        #expect(result.type == .lab)
    }

    @Test("病理强证据压制检验弱证据")
    func test_type_whenPathologyWithReferenceWord_returnsPathology() {
        let result = engine.extract("病理诊断报告\n病理号 S1\n建议参考临床", today: today)
        #expect(result.type == .pathology)
    }

    @Test("出院强证据判为出院小结")
    func test_type_whenDischargeEvidence_returnsDischarge() {
        let result = engine.extract("出院小结\n出院医嘱", today: today)
        #expect(result.type == .discharge)
    }

    @Test("门诊强证据判为门诊病历")
    func test_type_whenOutpatientEvidence_returnsOutpatient() {
        let result = engine.extract("门诊病历\n主诉：复查", today: today)
        #expect(result.type == .outpatient)
    }

    @Test("影像强证据判为影像报告")
    func test_type_whenImagingEvidence_returnsImaging() {
        let result = engine.extract("CT检查报告\n影像学表现", today: today)
        #expect(result.type == .imaging)
    }

    @Test("处方强证据判为处方")
    func test_type_whenPrescriptionEvidence_returnsPrescription() {
        let result = engine.extract("处方笺\nRx\n药品名称 用法用量", today: today)
        #expect(result.type == .prescription)
    }

    @Test("低分文本归其他且低置信")
    func test_type_whenNoEvidence_returnsOtherLow() {
        let result = engine.extract("今天感觉不错", today: today)
        #expect(result.type == .other)
        #expect(result.typeConfidence == .low)
    }

    @Test("类型并列时归其他")
    func test_type_whenScoresTie_returnsOther() {
        let result = engine.extract("检验报告 门诊病历", today: today)
        #expect(result.type == .other)
    }

    @Test("标准指标行提取值单位区间")
    func test_lab_whenStandardLine_extractsFields() {
        let result = engine.extract("检验报告\nTSH 0.08 ↓ mIU/L 0.27-4.20", today: today)
        let item = result.labItems.first
        #expect(item?.value == 0.08)
        #expect(item?.unit == "mIU/L")
        #expect(item?.refLow == 0.27)
        #expect(item?.refHigh == 4.20)
    }

    @Test("高箭头映射 high")
    func test_lab_whenUpArrow_setsHigh() {
        let result = engine.extract("检验报告\nFT4 22.8 ↑ pmol/L 12.0-22.0", today: today)
        #expect(result.labItems.first?.flag == .high)
    }

    @Test("低箭头映射 low")
    func test_lab_whenDownArrow_setsLow() {
        let result = engine.extract("检验报告\nTSH 0.08 ↓ mIU/L 0.27-4.20", today: today)
        #expect(result.labItems.first?.flag == .low)
    }

    @Test("H 标记映射 high")
    func test_lab_whenHMarker_setsHigh() {
        let result = engine.extract("检验报告\nALT 88 H U/L 7-40", today: today)
        #expect(result.labItems.first?.flag == .high)
    }

    @Test("L 标记映射 low")
    func test_lab_whenLMarker_setsLow() {
        let result = engine.extract("检验报告\nHGB 80 L g/L 115-150", today: today)
        #expect(result.labItems.first?.flag == .low)
    }

    @Test("无箭头出界自动补低标记与低置信")
    func test_lab_whenUnmarkedOutOfRange_infersLowConfidenceFlag() {
        let result = engine.extract("检验报告\nTg 0.06 µg/L 3.5-77.0", today: today)
        #expect(result.labItems.first?.flag == .low)
        #expect(result.labItems.first?.confidence == .low)
        #expect(result.abnormalFlags.isEmpty)
    }

    @Test("无箭头区间内维持正常")
    func test_lab_whenWithinRange_setsNone() {
        let result = engine.extract("检验报告\nFT3 5.9 pmol/L 3.1-6.8", today: today)
        let item = result.labItems.first
        #expect(item?.name == "FT3")
        #expect(item?.value == 5.9)
        #expect(item?.refLow == 3.1)
        #expect(item?.refHigh == 6.8)
        #expect(item?.flag == LabFlag.none)
        #expect(item?.confidence == .high)
    }

    @Test("电话号码不被当指标")
    func test_lab_whenPhoneNumber_ignoresLine() {
        let result = engine.extract("检验报告\n联系电话 13800138000\nTSH 1.2 mIU/L 0.27-4.2", today: today)
        #expect(result.labItems.count == 1)
    }

    @Test("无区间无箭头的数字行被忽略")
    func test_lab_whenNoRangeOrMarker_ignoresLine() {
        let result = engine.extract("检验报告\n样本编号 123456", today: today)
        #expect(result.labItems.isEmpty)
    }

    @Test("显式异常汇总但自动补异常不汇总")
    func test_lab_whenMixedConfidence_summarizesExplicitOnly() {
        let text = "检验报告\nTSH 0.08 ↓ mIU/L 0.27-4.20\nTg 0.06 µg/L 3.5-77.0"
        let result = engine.extract(text, today: today)
        #expect(result.labItems.count == 2)
        #expect(result.abnormalFlags.count == 1)
    }

    @Test("qd 映射每日一次")
    func test_medication_whenQD_mapsOnceDaily() {
        let result = engine.extract("处方笺\n二甲双胍片 500mg qd 口服", today: today)
        #expect(result.medicationHints.first?.frequencyPerDay == 1)
    }

    @Test("bid 映射每日两次")
    func test_medication_whenBID_mapsTwiceDaily() {
        let result = engine.extract("处方笺\n二甲双胍片 500mg bid 口服", today: today)
        #expect(result.medicationHints.first?.frequencyPerDay == 2)
    }

    @Test("tid 映射每日三次")
    func test_medication_whenTID_mapsThreeTimesDaily() {
        let result = engine.extract("处方笺\n二甲双胍片 500mg tid 口服", today: today)
        #expect(result.medicationHints.first?.frequencyPerDay == 3)
    }

    @Test("中文频次与用法可提取")
    func test_medication_whenChineseFrequency_extractsUsage() {
        let result = engine.extract("处理意见：\n左甲状腺素钠片 75µg 每日1次 晨起空腹口服", today: today)
        let hint = result.medicationHints.first
        #expect(hint?.frequencyPerDay == 1)
        #expect(hint?.usage.contains("晨起") == true)
        #expect(hint?.usage.contains("空腹") == true)
        #expect(hint?.confidence == .high)
    }

    @Test("正文药物线索为低置信")
    func test_medication_whenOutsideOrderSection_isLowConfidence() {
        let result = engine.extract("现病史：长期服用优甲乐100µg每日1次。", today: today)
        #expect(result.medicationHints.first?.confidence == .low)
    }

    @Test("无药名行不产生线索")
    func test_medication_whenNoDrugName_returnsEmpty() {
        let result = engine.extract("处理意见：注意休息。", today: today)
        #expect(result.medicationHints.isEmpty)
    }

    @Test("一个月复查折算三十天")
    func test_followUp_whenOneMonth_setsThirtyDays() {
        let text = "出院日期：2024-09-02\n术后1个月复查甲状腺功能"
        let result = engine.extract(text, today: today)
        #expect(result.followUpHints.first?.offsetDays == 30)
        #expect(result.followUpHints.first?.plannedDate == CTDate.make(2024, 10, 2))
    }

    @Test("三个月复查拆分两项")
    func test_followUp_whenMultipleItems_splitsItems() {
        let text = "就诊日期：2026-03-15\n3个月后复查颈部超声、甲状腺功能"
        let result = engine.extract(text, today: today)
        #expect(result.followUpHints.first?.offsetDays == 90)
        #expect(result.followUpHints.first?.items == ["颈部超声", "甲状腺功能"])
    }

    @Test("两周复查折算十四天")
    func test_followUp_whenWeeks_convertsToDays() {
        let result = engine.extract("检查日期：2026-01-01\n2周后复查血常规", today: today)
        #expect(result.followUpHints.first?.offsetDays == 14)
    }

    @Test("定期复查不虚构日期")
    func test_followUp_whenPeriodic_hasNoDate() {
        let result = engine.extract("定期复查甲状腺功能", today: today)
        #expect(result.followUpHints.first?.plannedDate == nil)
        #expect(result.followUpHints.first?.offsetDays == nil)
        #expect(result.followUpHints.first?.confidence == .low)
    }

    @Test("空文本返回安全空结果")
    func test_empty_whenWhitespace_returnsEmptyResult() {
        let result = engine.extract(" \n ", today: today)
        #expect(result == ExtractionResult.empty)
    }

    @Test("一万字文本可在预算内完成")
    func test_longText_whenTenThousandCharacters_completesQuickly() {
        let text = String(repeating: "普通病历段落。", count: 1_500) +
            "\n检查日期：2026-03-15\nCT检查报告\n影像学表现"
        let clock = ContinuousClock()
        let duration = clock.measure {
            _ = engine.extract(text, today: today)
        }
        #expect(duration < .seconds(2))
    }

    @Test("特殊字符医院名文本不崩溃")
    func test_specialCharacters_whenEmojiAndFullWidthParentheses_remainsStable() {
        let text = "四川大学华西医院（测试院区）🏥\n门诊病历\n就诊日期：2026-03-15"
        let result = engine.extract(text, today: today)
        #expect(result.hospital == "四川大学华西医院")
        #expect(result.type == .outpatient)
    }
}
