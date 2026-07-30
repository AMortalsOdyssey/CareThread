import Testing
@testable import CareThread

struct SmokeTests {
    @Test("应用的免责声明固定存在")
    func test_disclaimer_whenRead_isMedicalBoundary() {
        #expect(Copy.disclaimer.contains("不提供诊断"))
        #expect(Copy.disclaimer.contains("医生意见"))
    }
}

