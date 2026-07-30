import SwiftData
import Testing
@testable import CareThread

@MainActor
struct SeedServiceTests {
    @Test("演示种子生成唯一虚构患者")
    func test_seedDemo_whenEmpty_insertsOnePatient() throws {
        let container = try TestSupport.container()
        try SeedService.seedDemo(into: container.mainContext)
        let patients = try container.mainContext.fetch(FetchDescriptor<Patient>())
        #expect(patients.count == 1)
        #expect(patients.first?.name == "王晓芸")
        #expect(patients.first?.reportName == "王晓芸")
    }

    @Test("演示种子生成六份故事线记录")
    func test_seedDemo_whenEmpty_insertsSixRecords() throws {
        let container = try TestSupport.container()
        try SeedService.seedDemo(into: container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<MedicalRecord>()) == 6)
    }

    @Test("演示种子包含两段剂量版本")
    func test_seedDemo_whenEmpty_insertsMedicationChain() throws {
        let container = try TestSupport.container()
        try SeedService.seedDemo(into: container.mainContext)
        let medications = try container.mainContext.fetch(FetchDescriptor<Medication>())
        #expect(medications.count == 2)
        #expect(medications.contains { $0.doseValue == 75 && $0.isLongTerm })
        #expect(medications.contains { $0.doseValue == 100 && !$0.isLongTerm })
    }

    @Test("演示种子重复执行保持幂等")
    func test_seedDemo_whenCalledTwice_doesNotDuplicate() throws {
        let container = try TestSupport.container()
        try SeedService.seedDemo(into: container.mainContext)
        try SeedService.seedDemo(into: container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Patient>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<MedicalRecord>()) == 6)
    }

    @Test("压测种子按指定数量确定性生成")
    func test_seedStress_whenCountProvided_insertsExactCount() throws {
        let container = try TestSupport.container()
        try SeedService.seedStress(300, into: container.mainContext)
        let records = try container.mainContext.fetch(FetchDescriptor<MedicalRecord>())
        #expect(records.count == 300)
        #expect(Set(records.map(\.title)).count == 300)
    }

    @Test("压测种子负数输入安全归零")
    func test_seedStress_whenNegative_insertsNothing() throws {
        let container = try TestSupport.container()
        try SeedService.seedStress(-4, into: container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<MedicalRecord>()) == 0)
    }
}
