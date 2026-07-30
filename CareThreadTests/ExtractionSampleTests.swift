import Testing
@testable import CareThread

struct ExtractionSampleTests {
    private let engine = ExtractionEngine()
    private let today = CTDate.make(2026, 7, 30)

    @Test("F1 病理报告关键字段命中")
    func test_extract_whenF1Pathology_matchesExpectedFields() throws {
        let result = engine.extract(try TestSupport.fixture("f1"), today: today)
        #expect(result.type == .pathology)
        #expect(result.eventDate == CTDate.make(2024, 8, 22))
        #expect(result.hospital == "四川大学华西医院")
        #expect(result.department == "甲状腺外科")
        #expect(result.summary.contains("甲状腺乳头状癌"))
        #expect(result.title.contains("病理"))
    }

    @Test("F2 出院小结优先取出院日期并提取用药复查")
    func test_extract_whenF2Discharge_matchesExpectedFields() throws {
        let result = engine.extract(try TestSupport.fixture("f2"), today: today)
        #expect(result.type == .discharge)
        #expect(result.eventDate == CTDate.make(2024, 9, 2))
        #expect(result.structuredFields.contains { $0.key == "入院日期" && $0.value == "2024-08-23" })
        let medication = try #require(result.medicationHints.first { $0.doseValue == 100 })
        #expect(medication.name == "左甲状腺素钠片")
        #expect(medication.doseUnit == "µg")
        #expect(medication.frequencyPerDay == 1)
        #expect(medication.usage.contains("空腹"))
        #expect(medication.confidence == .high)
        #expect(result.followUpHints.contains { $0.offsetDays == 30 && $0.items.contains("甲状腺功能") })
        #expect(result.followUpHints.contains { $0.offsetDays == 90 && $0.items.contains("颈部超声") })
    }

    @Test("F3 甲功五项提取五行与两项显式异常")
    func test_extract_whenF3Lab_matchesExpectedFields() throws {
        let result = engine.extract(try TestSupport.fixture("f3"), today: today)
        #expect(result.type == .lab)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
        #expect(result.hospital == "四川大学华西医院")
        #expect(result.department == "内分泌科")
        #expect(result.labItems.count >= 5)
        #expect(result.abnormalFlags.count == 2)
        let tsh = try #require(result.labItems.first { $0.name.contains("TSH") })
        let ft4 = try #require(result.labItems.first { $0.name.contains("FT4") })
        let ft3 = try #require(result.labItems.first { $0.name.contains("FT3") })
        #expect(tsh.value == 0.08)
        #expect(tsh.flag == .low)
        #expect(ft4.flag == .high)
        #expect(ft3.flag == .none)
        #expect(result.title.contains("甲状腺功能五项"))
    }

    @Test("F4 超声报告类型与无异常结论命中")
    func test_extract_whenF4Ultrasound_matchesExpectedFields() throws {
        let result = engine.extract(try TestSupport.fixture("f4"), today: today)
        #expect(result.type == .imaging)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
        #expect(result.department == "内分泌科")
        #expect(result.summary.contains("未见明确复发"))
        #expect(result.abnormalFlags.isEmpty)
        #expect(result.title.contains("颈部超声"))
    }

    @Test("F5 门诊病历区分历史用药与高置信处理意见")
    func test_extract_whenF5Outpatient_matchesExpectedFields() throws {
        let result = engine.extract(try TestSupport.fixture("f5"), today: today)
        #expect(result.type == .outpatient)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
        #expect(result.department == "甲状腺外科")
        let historical = try #require(result.medicationHints.first { $0.doseValue == 100 })
        let adjusted = try #require(result.medicationHints.first { $0.doseValue == 75 })
        #expect(historical.confidence == .low)
        #expect(adjusted.confidence == .high)
        #expect(adjusted.name == "左甲状腺素钠片")
        #expect(result.followUpHints.contains { $0.offsetDays == 90 && $0.items.contains("甲状腺功能") })
    }

    @Test("F6 CT 报告关键字段命中")
    func test_extract_whenF6CT_matchesExpectedFields() throws {
        let result = engine.extract(try TestSupport.fixture("f6"), today: today)
        #expect(result.type == .imaging)
        #expect(result.eventDate == CTDate.make(2025, 11, 3))
        #expect(result.hospital == "成都市第三人民医院")
        #expect(result.department == "放射科")
        #expect(result.summary.contains("未见明显异常"))
        #expect(result.title.contains("胸部CT平扫"))
    }
}

