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
        ensureKeyboardFocus(file: file, line: line)
        typeText(text)
    }

    func clearAndType(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        ensureKeyboardFocus(file: file, line: line)
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
            ensureKeyboardFocus(file: file, line: line)
            typeText(XCUIKeyboardKey.delete.rawValue)
        } else if existingCharacterCount > 0 {
            ensureKeyboardFocus(file: file, line: line)
            typeText(
                String(
                    repeating: XCUIKeyboardKey.delete.rawValue,
                    count: existingCharacterCount
                )
            )
        }
        ensureKeyboardFocus(file: file, line: line)
        typeText(text)
    }

    func replaceExistingValue(
        with text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        ensureKeyboardFocus(file: file, line: line)
        let current = value as? String ?? ""
        if !current.isEmpty {
            typeText(
                String(
                    repeating: XCUIKeyboardKey.delete.rawValue,
                    count: current.count
                )
            )
        }
        ensureKeyboardFocus(file: file, line: line)
        typeText(text)
    }

    private func ensureKeyboardFocus(
        file: StaticString,
        line: UInt
    ) {
        for _ in 0..<3 {
            if reportsKeyboardFocus {
                return
            }
            tap()
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline {
                if reportsKeyboardFocus {
                    return
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.05)
                )
            }
        }
        XCTFail(
            "输入控件在 3 次点击后仍未获得键盘焦点：\(identifier)",
            file: file,
            line: line
        )
    }

    /// `hasKeyboardFocus` is present in the XCTest accessibility snapshot but
    /// Xcode 26.6 does not expose it as a Swift `XCUIElement` property.
    private var reportsKeyboardFocus: Bool {
        NSPredicate(format: "hasKeyboardFocus == true")
            .evaluate(with: self)
    }
}
