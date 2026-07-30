# CareThread 实施日志

> 用途：按里程碑记录实现选择、验证证据与查漏结果，便于阶段 review。每个里程碑提交前更新；`PROGRESS.md` 记录结论，本文件保留过程与依据。

## 2026-07-30 / M0 骨架与基建

### 实现

- 用 XcodeGen 2.46.0 建立 iOS 17.0+、Swift 5 语言模式工程；生成的 `.xcodeproj` 不入库。
- 标准版先建立 5 槽根导航，老人版建立 3 槽根导航；显示模式可由 `@AppStorage` 持久化并可用 `-displayMode` 启动参数覆盖。
- 将设计规范 §3–§5 的基础色、语义色、类型色、字号、间距、圆角和尺寸落为 `CT` token；颜色全部进入带 Light/Dark 外观的 Assets catalog。
- 建立 `verify.sh`、`acceptance.sh`、`screenshots.sh` 与进度/阻塞文档。

### 验证证据

- `Scripts/verify.sh`：退出码 0。
- Swift Testing：1/1 通过；XCUITest：1/1 通过。
- Computer Use：在 iPhone 16 / iOS 18.6 模拟器打开 CareThread，核对五槽 Tab、暖纸白背景和医用青主色实际渲染。
- Git：`75ea563 M0: 骨架与基建完成`。

### 查漏

- AppIcon 仍是空槽，按任务书留到 M8 读取视觉资产规范后补齐。
- `screenshots.sh` 目前只有安全骨架，M8 接入 18 个确定性页面状态与双外观采集。
- `acceptance.sh` 的测试计数、截图计数、Info.plist、依赖白名单校验将在对应产物出现后逐步收紧，M9 必须一次性全 PASS。

## 2026-07-31 / M1 数据层

### 实现

- SwiftData 七类实体、值类型与关系。
- 固定时钟注入、年龄计算、附件 Vault 不可变写入、CRUD/删除文件调度、用药剂量调整链。
- 六记录故事线种子与 300 条确定性压测数据。

### 验证证据

- `Scripts/verify.sh`：退出码 0。
- Swift Testing：31/31 通过；XCUITest：1/1 通过。
- 记录三层数据、级联关系、删除文件调度与剂量调整链均经过内存 ModelContainer 真实往返。
- Vault 在模拟器沙盒真实写入工作副本和 `originals/` 原件，覆盖不可变、防目录穿越、缺失文件与孤儿扫描。
- 红线扫描：联网实现、未完成标识均零命中。

### 查漏

- [x] 内存 ModelContainer CRUD 与 cascade 行为
- [x] 2/29、生日缺失、生日晚于事件、手填年龄优先
- [x] Vault 路径防穿越、写入后不可覆盖、缺失文件与孤儿扫描
- [x] 剂量调整旧止期、新版本 `previousVersionId`
- [x] `verify.sh` 全绿且单测不少于 14（实际 31）

### 已知诊断

- iOS 18.6 模拟器在首次构造 SwiftData schema 时会输出数组属性的 Core Data materialization 诊断；实际插入、保存、重新抓取的数组字段均通过测试。当前不影响功能，后续在持久化库迁移与备份往返阶段再次复核。
