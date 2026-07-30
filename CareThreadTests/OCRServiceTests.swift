import Testing
import UIKit
@testable import CareThread

struct OCRServiceTests {
    @Test("打印甲功样张经 Vision 后可进入提取闭环", .timeLimit(.minutes(1)))
    func test_vision_whenRenderedLab_recognizesProductFields() async throws {
        let source = try TestSupport.fixture("f3")
        let image = TextFixtureRenderer.image(text: source, fontSize: 34)
        let page = try await VisionOCREngine().recognize(image, pageIndex: 0)
        let result = ExtractionEngine().extract(
            page.text,
            today: CTDate.make(2026, 7, 30),
            engineIdentifier: "apple-vision"
        )
        #expect(!page.blocks.isEmpty)
        #expect(result.type == .lab)
        #expect(result.eventDate == CTDate.make(2026, 3, 15))
        #expect(result.hospital?.contains("华西医院") == true)
    }

    @Test("打印 CT 样张经 Vision 后可进入提取闭环", .timeLimit(.minutes(1)))
    func test_vision_whenRenderedCT_recognizesProductFields() async throws {
        let source = try TestSupport.fixture("f6")
        let image = TextFixtureRenderer.image(text: source, fontSize: 34)
        let page = try await VisionOCREngine().recognize(image, pageIndex: 0)
        let result = ExtractionEngine().extract(
            page.text,
            today: CTDate.make(2026, 7, 30),
            engineIdentifier: "apple-vision"
        )
        #expect(!page.blocks.isEmpty)
        #expect(result.type == .imaging)
        #expect(result.eventDate == CTDate.make(2025, 11, 3))
        #expect(result.department == "放射科")
    }

    @Test("纯白图片返回零文本而非崩溃", .timeLimit(.minutes(1)))
    func test_vision_whenBlankImage_returnsEmptyBlocks() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        let page = try await VisionOCREngine().recognize(image, pageIndex: 3)
        #expect(page.pageIndex == 3)
        #expect(page.blocks.isEmpty)
        let extracted = ExtractionEngine().extract(page.text, today: CTDate.make(2026, 7, 30))
        #expect(extracted == .empty)
    }
}

