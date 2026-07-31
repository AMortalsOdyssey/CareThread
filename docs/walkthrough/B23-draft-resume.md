# B23 草稿恢复与老人版降复杂

- `ModelTests.test_captureDraft_whenInserted_roundTripsState` 将草稿写入 SwiftData 后重新读取，验证附件路径、选择类型与原始 OCR 保留。
- 标准版来源页提供 `m3.source.continueDraft`，恢复时重新校验冻结成员与 generation；保存成功后删除已消费草稿。
- `ElderModeTests.elderHidesStandardDraftResume` 验证标准版显示续录策略、老人版不显示复杂草稿入口；老人流程仍把中断页保存在本机并交给标准版整理。
- 结果：中断/重启不丢已保存草稿；老人版不暴露难以理解的高级入口，也没有删除底层资料。
