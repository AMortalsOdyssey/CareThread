# B16 超大文档软限制

- 自动化：`CaptureVaultServiceTests.largeDocument_requiresExplicitSoftLimitAcknowledgement` 构造 22 页同一报告。
- 首次确认被阻止，并显示“当前报告超过 20 页……”的拆分建议；只有点击“确认属于同一份报告，继续”后才允许进入下一步。
- 性能代理：`PerformanceCrashAuditTests` 循环评估 100 页批次、50 页文档与 22 页软限制，共 17,200 页状态计算，要求 15 秒内完成。
- 结果：软限制是告知与显式确认，不丢页、不静默拆分，也不因大页数崩溃。
