import XCTest

extension XCUIElement {
    /// Gives software-keyboard focus up to three bounded attempts before typing.
    ///
    /// Xcode 26.6 simulators can briefly report a hittable text field before
    /// keyboard focus settles. Every UI test typing path goes through this
    /// helper so an environmental focus wobble cannot silently drop input.
    func focusAndType(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard ensureKeyboardFocus(file: file, line: line) else { return }
        typeText(text)
    }

    func clearAndType(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard ensureKeyboardFocus(file: file, line: line) else { return }
        let existingCharacterCount = (value as? String)?.count ?? 0
        press(forDuration: 0.8)
        let application = XCUIApplication()
        let englishSelectAll = application.menuItems["Select All"]
        let chineseSelectAll = application.menuItems["全选"]
        let selectAll = englishSelectAll.waitForExistence(timeout: 0.5)
            ? englishSelectAll
            : chineseSelectAll
        if selectAll.waitForExistence(timeout: 0.5) {
            selectAll.tap()
            guard ensureKeyboardFocus(file: file, line: line) else { return }
            typeText(XCUIKeyboardKey.delete.rawValue)
        } else if existingCharacterCount > 0 {
            guard ensureKeyboardFocus(file: file, line: line) else { return }
            typeText(
                String(
                    repeating: XCUIKeyboardKey.delete.rawValue,
                    count: existingCharacterCount
                )
            )
        }
        guard ensureKeyboardFocus(file: file, line: line) else { return }
        typeText(text)
    }

    func replaceExistingValue(
        with text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard ensureKeyboardFocus(file: file, line: line) else { return }
        let current = value as? String ?? ""
        if !current.isEmpty {
            typeText(
                String(
                    repeating: XCUIKeyboardKey.delete.rawValue,
                    count: current.count
                )
            )
        }
        guard ensureKeyboardFocus(file: file, line: line) else { return }
        typeText(text)
    }

    private func ensureKeyboardFocus(
        file: StaticString,
        line: UInt
    ) -> Bool {
        // Keep the first semantic tap so XCTest can scroll an ordinary field
        // above the keyboard. A vertical-axis SwiftUI TextField can expose an
        // accessibility scrollbar across its center, so only the bounded
        // retries use off-centre hit points.
        let retryOffsets: [CGFloat?] = [nil, 0.25, 0.75]
        for verticalOffset in retryOffsets {
            if reportsKeyboardFocus {
                return true
            }
            if let verticalOffset {
                coordinate(
                    withNormalizedOffset: CGVector(
                        dx: 0.5,
                        dy: verticalOffset
                    )
                ).tap()
            } else {
                tap()
            }
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                if reportsKeyboardFocus {
                    return true
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.05)
                )
            }
            // A partially visible SwiftUI field can report `isHittable` while
            // its synthesized tap lands on the safe-area boundary. Move it
            // away from that boundary before the next bounded focus attempt.
            let application = XCUIApplication()
            if frame.midY > application.frame.maxY - 80 {
                application.swipeUp()
            } else if frame.midY < application.frame.minY + 80 {
                application.swipeDown()
            }
        }
        XCTFail(
            "输入控件在 3 次点击后仍未获得键盘焦点：\(identifier)",
            file: file,
            line: line
        )
        return false
    }

    /// `hasKeyboardFocus` is present in the XCTest accessibility snapshot but
    /// Xcode 26.6 does not expose it as a Swift `XCUIElement` property.
    private var reportsKeyboardFocus: Bool {
        NSPredicate(format: "hasKeyboardFocus == true")
            .evaluate(with: self)
    }
}
