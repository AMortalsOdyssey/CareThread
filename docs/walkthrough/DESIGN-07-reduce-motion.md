# DESIGN-07 减弱动态效果走查

- 在 iPhone 16 / iOS 18.6 模拟器临时开启 `ReduceMotionEnabled`，启动确定性时间线路由并视觉核对；页面稳定显示，无循环、闪烁或缩放动画，完成后恢复模拟器默认设置。
- `TimelineView` 在 `accessibilityReduceMotion` 为真时直接 `scrollTo`，不执行 `.smooth` 动画。
- `NearbySyncView` 在发现阶段把 transaction animation 置空；大字版静态扫描禁止 `.scaleEffect`、`.repeatForever` 与 `.symbolEffect`。
- 自动化：`DesignSpecConformanceTests.elderSourcesAvoidHiddenGesturesAndMotionResidue`。
- 结果：减弱动态效果打开时关键流程仍可用，且没有必须依赖动画才能理解的状态变化。
