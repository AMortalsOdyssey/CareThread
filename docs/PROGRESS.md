# CareThread 实施进度

详细过程、验证证据与每阶段查漏项见 [`IMPLEMENTATION_LOG.md`](IMPLEMENTATION_LOG.md)；阻塞与降级路径见 [`BLOCKERS.md`](BLOCKERS.md)。

## M0 骨架与基建

- 状态：完成
- 基线：Xcode 16.4、Swift 5 语言模式、iOS 17.0+、iPhone 16 / iOS 18.6。
- 已创建 XcodeGen 工程、标准版五槽与老人版三槽根结构、完整设计 token 骨架、Light/Dark 颜色资产入口、验证脚本。
- 验证：`Scripts/verify.sh` 退出码 0；Swift Testing 1/1、XCUITest 1/1；Computer Use 打开模拟器核对五槽 Tab 壳与暖纸白/医用青 token 生效。

## M1 数据层

- 状态：完成
- 实现：SwiftData 七类实体与三层记录数据、固定日期注入、年龄计算、附件 Vault 不可变双份写入与路径防穿越、记录删除文件清理、用药剂量版本链、六记录故事线种子和 300 条压测数据。
- 验证：`Scripts/verify.sh` 退出码 0；Swift Testing 31/31、XCUITest 1/1；覆盖年龄 9 项、Vault 9 项、模型/关系 6 项、种子 6 项与免责声明冒烟 1 项。
- 红线：联网标识扫描、未完成标识扫描均零命中。

## M2 OCR 与提取引擎

- 状态：完成
- 实现：`OCREngine` / `TextBlock` 协议、Apple Vision 离线引擎、文本样张渲染器、纯函数 `ExtractionEngine`；覆盖日期、医院/科室、类型评分、检验指标、用药线索、复查线索、摘要与标题。
- 样张：05 §5 的 `f1`–`f6` 与期望 JSON 已原样落入 `CareThreadTests/Fixtures/`；六份文本规则闭环全部通过。
- 真实 OCR：打印版甲功与 CT 样张经 Core Graphics 渲染 → Vision → 提取引擎闭环通过；纯白图零文本安全通过。
- 验证：`Scripts/verify.sh` 退出码 0；Swift Testing 85/85、XCUITest 1/1。单测数量已达到最终下限，后续里程碑继续增加而不削减。

## 真机验收（开发完成后由用户执行）

- [ ] VisionKit 相机扫描、自动裁边与多页连拍
- [ ] FaceID 解锁与冷启动/回前台 60 秒锁定
- [ ] 标准版与老人版通知真实到达及点击落点
- [ ] 真实病历、手写处方、化验单与发票 OCR 体感
- [ ] 备份 ZIP 在 Mac 解包可读、就诊摘要 PDF 打印效果
- [ ] 老人版真人零指导完成一次“拍照存报告”和一次“看今天的药”
