# DESIGN-06 Dynamic Type 走查

- 标准版 AX3：XCUITest `testDesignStandardAX3KeepsPrimaryFlowsReachable` 在 `UICTContentSizeCategoryAccessibilityXL` 下依次验证首页、录入确认页、记录详情页，主操作可滚动到达且可点击；定向重跑 1/1 通过。
- 大字版：`ElderModeTests.dynamicTypeCapsAtAX2` 验证系统更大字号被明确封顶到 AX2；`ElderModeUITests.testB21AccessibilitySizeKeepsPrimaryActionsHittable` 验证医生卡和六个资料类型按钮仍可点击且按钮高度至少 60pt。
- 字体实现：`CTFont.swift` 使用公开 `UIFont.systemFont`、`UIFontMetrics.scaledFont` 和 `SwiftUI.Font(UIFont)`，不使用私有 `.SFUI-*` 字体名。
- 结果：未发现主操作消失、文字覆盖或不可点击项；系统字体缩放不再产生 CoreText 回退警告。
