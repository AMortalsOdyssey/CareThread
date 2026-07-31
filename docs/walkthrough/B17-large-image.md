# B17 超大图片与原件不变

- `CaptureVaultServiceTests.highEntropyBulkStaging_isSinglePageBoundedAndOrdered` 使用 4096×3072 高熵 JPEG，逐页暂存并验证并发上限 1、顺序与每页原件哈希。
- `PerformanceCrashAuditTests.fortyEightMegapixel_originalHashAndWorkingImage` 生成 8000×6000 的真实 48MP 虚构 JPEG，验证工作图为 3000×2250。
- 原件文件大小和 SHA-256 在暂存后逐字节保持一致；预览使用独立派生文件。
- 结果：预览降采样不会改写真实数据源；大图处理有界且失败时清理本批次前缀。
