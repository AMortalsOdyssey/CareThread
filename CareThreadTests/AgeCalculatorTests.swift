import Foundation
import Testing
@testable import CareThread

struct AgeCalculatorTests {
    @Test("正常日期按完整周岁计算")
    func test_age_whenAfterBirthday_returnsWholeYears() {
        let result = AgeCalculator.age(
            birthday: CTDate.make(1992, 6, 18),
            at: CTDate.make(2026, 7, 30),
            manualAge: nil
        )
        #expect(result == AgeResult(age: 34, hasInvalidChronology: false, source: .calculated))
    }

    @Test("事件日就是生日当天时增长一岁")
    func test_age_whenEventIsBirthday_returnsNewAge() {
        let result = AgeCalculator.age(
            birthday: CTDate.make(1992, 6, 18),
            at: CTDate.make(2025, 6, 18),
            manualAge: nil
        )
        #expect(result.age == 33)
    }

    @Test("事件日在生日之前时不提前增长")
    func test_age_whenBeforeBirthday_returnsPreviousAge() {
        let result = AgeCalculator.age(
            birthday: CTDate.make(1992, 6, 18),
            at: CTDate.make(2025, 6, 17),
            manualAge: nil
        )
        #expect(result.age == 32)
    }

    @Test("2月29日生日在平年3月1日稳定计算")
    func test_age_whenLeapDayBirthdayInCommonYear_returnsValidAge() {
        let result = AgeCalculator.age(
            birthday: CTDate.make(1992, 2, 29),
            at: CTDate.make(2025, 3, 1),
            manualAge: nil
        )
        #expect(result.age == 33)
        #expect(!result.hasInvalidChronology)
    }

    @Test("生日缺失时年龄不可用但不警示")
    func test_age_whenBirthdayMissing_returnsUnavailable() {
        let result = AgeCalculator.age(
            birthday: nil,
            at: CTDate.make(2026, 7, 30),
            manualAge: nil
        )
        #expect(result == AgeResult(age: nil, hasInvalidChronology: false, source: .unavailable))
    }

    @Test("生日晚于事件日期时返回警示")
    func test_age_whenBirthdayAfterEvent_returnsChronologyWarning() {
        let result = AgeCalculator.age(
            birthday: CTDate.make(2000, 1, 1),
            at: CTDate.make(1998, 1, 1),
            manualAge: nil
        )
        #expect(result.age == nil)
        #expect(result.hasInvalidChronology)
    }

    @Test("手填年龄优先于生日计算")
    func test_age_whenManualProvided_prefersManualValue() {
        let result = AgeCalculator.age(
            birthday: CTDate.make(2000, 1, 1),
            at: CTDate.make(2026, 1, 1),
            manualAge: 31
        )
        #expect(result == AgeResult(age: 31, hasInvalidChronology: false, source: .manual))
    }

    @Test("负数手填年龄被拒绝")
    func test_age_whenManualNegative_returnsWarning() {
        let result = AgeCalculator.age(
            birthday: nil,
            at: CTDate.make(2026, 1, 1),
            manualAge: -1
        )
        #expect(result.age == nil)
        #expect(result.hasInvalidChronology)
    }

    @Test("超过合理范围的手填年龄被拒绝")
    func test_age_whenManualTooLarge_returnsWarning() {
        let result = AgeCalculator.age(
            birthday: nil,
            at: CTDate.make(2026, 1, 1),
            manualAge: 131
        )
        #expect(result.age == nil)
        #expect(result.source == .unavailable)
    }
}

