---
title: CareThread OCR 选型调研与集成报告
created: "2026-07-31"
updated: "2026-07-31"
status: final
---

# CareThread OCR 选型调研与集成报告

## 0. 唯一结论

**CareThread 一期继续使用 Apple Vision 单引擎，不引入 RapidOCR、Paddle-Lite、ML Kit、Tesseract 或其他 OCR 运行时。**

RapidOCR PP-OCRv5 mobile / ONNX Runtime 在百分制加权中以 79.74 分高于
Vision 的 40.00 分，但它相对 Vision 的手写 CER 只改善 **1.56 个百分点**
（3.92% → 2.37%），没有达到任务书要求的 **至少 10 个百分点**；打印
CER 改善 3.64 个百分点，满足“不劣化超过 1 个百分点”。两条换引擎条件
必须同时成立，因此固定规则的结果是维持 Vision。

这不是“二选一建议”，而是按任务书 §5 自动得出的最终决定。发布 App
不增加第三方 OCR 依赖、模型、运行时下载、遥测或联网行为。

## 1. 调研口径与官方证据

调研日期为 2026-07-31。许可证、iOS 路径、隐私、模型体积和维护性优先
引用项目官方文档、官方仓库与许可证原文。

### 1.1 Apple Vision

- Apple 将 `VNRecognizeTextRequest` 定义为查找并识别图中文字的图像分析请求，
  支持准确度/速度级别、识别语言、语言纠错与归一化框。
- Apple 官方明确写道：**“all of Vision’s processing happens on the user’s device”**。
  这直接满足完全离线和隐私红线。
- 系统框架不增加模型包体，无账号、API key 或用量费用；作为 Apple 系统能力，
  按任务书豁免维护活跃门槛。

来源：

- [Apple｜VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [Apple｜Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images)

### 1.2 PaddleOCR / RapidOCR / ONNX Runtime 路径

- PaddleOCR 与 RapidOCR 均为 Apache-2.0；ONNX Runtime 为 MIT，允许闭源商用
  集成。Apache 许可证原文授予 “perpetual, worldwide, non-exclusive,
  no-charge, royalty-free” 的复制、修改与分发许可，但发布时仍须保留
  许可证和适用 NOTICE。
- PaddleOCR 官方列出 `PP-OCRv5_mobile_rec` 模型约 16 MB，并说明该代覆盖
  **“handwriting, vertical text, pinyin, and rare characters”** 等复杂文本。
- RapidOCR 官方仓库在 2026-04-11 发布 v3.8.1，满足 18 个月活跃门槛；本次
  实测使用 3.8.4 包中的 PP-OCRv5 mobile ONNX 权重。
- ONNX Runtime 官方列出 iOS Objective-C 的 `onnxruntime-objc` 包，并说明
  模型在设备上加载和运行；因此这条路径在技术上可集成 iOS。RapidOCR 的
  检测/裁切/后处理仍需 Swift/ObjC 适配，集成风险按“成熟社区路径”计 7 分，
  不是 Apple 官方 API 的 10 分。
- 本次三模型加 arm64 ONNX Runtime dylib 的实测上界为 48.9 MB，低于 60 MB
  硬门槛；macOS 进程预热后峰值内存增量为 1567.3 MB，是明显的移动端工程
  风险。PaddleOCR 官方 PP-OCRv5 基准同样报告较高峰值内存，方向一致。

来源：

- [PaddleOCR｜Apache-2.0 LICENSE](https://github.com/PaddlePaddle/PaddleOCR/blob/main/LICENSE)
- [PaddleOCR｜PP-OCRv5 文字识别模型](https://paddlepaddle.github.io/PaddleOCR/main/en/version3.x/module_usage/text_recognition.html)
- [PaddleOCR｜PP-OCRv5 说明与内存数据](https://paddlepaddle.github.io/PaddleOCR/main/en/version3.x/algorithm/PP-OCRv5/PP-OCRv5.html)
- [RapidOCR｜仓库、Apache-2.0 与发布](https://github.com/RapidAI/RapidOCR)
- [RapidOCR｜Releases](https://github.com/RapidAI/RapidOCR/releases)
- [ONNX Runtime｜MIT LICENSE](https://github.com/microsoft/onnxruntime/blob/main/LICENSE)
- [ONNX Runtime｜iOS 安装矩阵](https://onnxruntime.ai/docs/install/)
- [ONNX Runtime｜移动端部署](https://onnxruntime.ai/docs/tutorials/mobile/)

### 1.3 Google ML Kit Text Recognition v2

- Google 的 iOS 文档说明中文资源在构建时静态链接，单 script SDK 约 38 MB，
  表面满足包体和模型随包要求。
- 但 Google 隐私条款原文同时写明：**“may contact Google servers from time
  to time”**，并且 **“send metrics about the performance and utilization”**。
  Google 的 Apple 数据披露页还列出设备信息、Bundle ID、安装标识符、性能
  指标、API 配置、事件类型和错误码。
- CareThread 红线是零联网代码/行为，且候选若有强制遥测而不能编译期关闭即
  出局。因此 ML Kit 在硬门槛 1 即淘汰，不进入基准和评分；输入图片本身不上传
  不能抵消遥测与服务器联系这一事实。

来源：

- [Google｜iOS Text Recognition v2](https://developers.google.com/ml-kit/vision/text-recognition/v2/ios)
- [Google｜ML Kit Terms & Privacy](https://developers.google.com/ml-kit/terms)
- [Google｜Apple App Store data disclosure](https://developers.google.com/ml-kit/ios-data-disclosure)

### 1.4 Tesseract 5

- Tesseract 核心为 Apache-2.0，5.5.2 于 2025-12-26 发布，核心本身活跃。
- 但 iOS 主流 Swift 包装 `SwiftyTesseract` 的仓库原文为：**“This library is
  no longer maintained”**，并在 2022-04-08 归档；较老的
  `Tesseract-OCR-iOS` 仍捆绑 Tesseract 3.03-rc1，而非当前 5.x。
- 因而 Tesseract 在“iOS 真实可集成的成熟路径”和“近 18 个月维护活跃”两项
  组合门槛上出局，不值得为了预期较弱的中文手写能力自行维护新包装。

来源：

- [Tesseract｜Apache-2.0 LICENSE](https://github.com/tesseract-ocr/tesseract/blob/main/LICENSE)
- [Tesseract｜5.5.2 Releases](https://github.com/tesseract-ocr/tesseract/releases)
- [SwiftyTesseract｜归档与停止维护说明](https://github.com/SwiftyTesseract/SwiftyTesseract)
- [Tesseract-OCR-iOS｜旧版上游说明](https://github.com/gali8/Tesseract-OCR-iOS)

### 1.5 chineseocr_lite / ncnn 与 TrOCR

- `chineseocr_lite` 官方仓库标注 GPL-2.0，触发许可证红线，直接出局；其
  TNN iOS 示例不能改变上游模型/代码的 GPL 条件。
- 社区中文 TrOCR 权重没有在本时间盒内找到同时满足许可证清晰、≤60 MB、
  近 18 个月维护、成熟 iOS 集成和无需自行转换的组合，按硬门槛 3/4/6
  不入围。它只保留为未来模型路线，不进入本次评分或 App。

来源：

- [chineseocr_lite｜GPL-2.0 官方仓库](https://github.com/DayBreak-u/chineseocr_lite)

## 2. 硬门槛结论

| 候选 | 离线/无遥测 | 许可证 | iOS 路径 | arm64 增量 | 无账号/免费 | 活跃 | 结论 |
| --- | --- | --- | --- | ---: | --- | --- | --- |
| Apple Vision | 是，设备端 | 系统框架 | Apple 官方 | 0 MB | 是 | 豁免 | 入围 |
| PaddleOCR PP-OCRv5 via RapidOCR/ORT | 是，显式本地模型；基准封死 socket | Apache-2.0 + MIT | ORT 官方 iOS + 社区 OCR 适配 | 48.9 MB 上界 | 是 | 是 | 入围 |
| Google ML Kit Chinese | 否，会联系服务器并发指标 | 专有免费条款 | 官方 CocoaPods | 约 38 MB | 是 | 是 | 硬门槛 1 出局 |
| Tesseract 5 + iOS wrapper | 是 | Apache-2.0/MIT | 主流包装归档或捆绑 3.x | 未测 | 是 | 包装否 | 硬门槛 3/6 出局 |
| chineseocr_lite | 是 | GPL-2.0 | 社区 TNN | 约 4.7 MB 模型 | 是 | 非关键 | 硬门槛 2 出局 |
| 中文 TrOCR 社区权重 | 可设计为离线 | 权重不统一 | 需自行转换/适配 | 未证实 | 不统一 | 未证实 | 硬门槛 3/4/6 出局 |

## 3. 可复现基准

### 3.1 数据集

测试集只含虚构数据，位于 `Benchmarks/OCRBench/testset/`：

- P 组 6 张：`f1`–`f6`，PingFang SC 34 px，等效 2x 下 17 pt。
- H 组 16 张：六份样张加两份虚构短处方，分别用 Hannotate SC 与
  HanziPen SC 渲染。
- D 组 8 张：4 张打印、4 张手写，固定随机种子，旋转 3–5°、高斯模糊、
  单侧二次阴影与 JPEG 50–61 质量压缩。
- O 组 1 张：虚构收费票据，只观察、不计分。

字体文件、字号、画布、换行、退化参数和随机种子全部固化在
`generate_testset.py`；`manifest.json` 记录每张图的参考文本和预期字段。
H 组只是可复现的手写字体近似，真实医生连笔通常更难，这是本基准的主要局限。

### 3.2 运行方法

仓库根目录执行：

```sh
Benchmarks/OCRBench/run.sh
```

脚本生成测试集、运行两个引擎、把 OCR 文本喂给仓库实际
`ExtractionEngine`、计算 CER/字段命中率/P95，并输出：

- `Benchmarks/OCRBench/results/raw/`：逐页 OCR、耗时、置信度、字段命中与
  模型 SHA-256。
- `Benchmarks/OCRBench/results/results.json`：逐页 CER、汇总指标、评分分量
  与机器可读决定。
- `Benchmarks/OCRBench/results/RESULTS.md`：面向 review 的结果表。

RapidOCR 使用显式本地模型路径并校验官方 SHA-256；加载和推理期间替换
`socket.socket` 为拒绝实现，网络尝试会立即失败。模型下载只发生在隔离的
开发基准环境初始化，不存在于 App，也不存在运行时下载代码。

### 3.3 指标定义

- CER：Unicode NFKC 后移除空白和换行，按总编辑距离 / 总参考字符数微平均。
- 手写 CER：H 组加 D 组手写子集，共 20 页。
- 打印 CER：P 组加 D 组打印子集，共 10 页。
- 字段命中：每页日期、医院、类型、关键指标四项；OCR 文本统一进入当前
  `ExtractionEngine`，不为任何候选改规则。
- 延迟：预热后每页 3 次，报告全部计分页的 P95。
- 模拟器：Apple Vision 在 iPhone 16 / iOS 18.6 跑 30×3 次，原始 JSON
  由 XCTest `keepAlways` 附件导出。挑战者未进入发布集成，因此没有伪造
  iOS 模拟器延迟；以 “not integrated” 明示。
- 包体：模型文件加 arm64 ONNX Runtime dylib 实测上界；Vision 为系统框架 0。
- 内存：引擎预热后进程 RSS 峰值增量；不同运行时不可视为真机绝对值，
  仅用于风险观察。

## 4. 原始结果

| 引擎 | 打印 CER | 手写 CER | 字段命中 | P95 M 系 Mac | P95 模拟器 | 峰值内存增量 | arm64 包体增量 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple Vision | 5.98% | 3.92% | 113/120（94.17%） | 229 ms | 695 ms | 59.6 MB | 0.0 MB |
| RapidOCR PP-OCRv5 mobile / ORT | 2.34% | 2.37% | 105/120（87.50%） | 640 ms | 未集成，不伪造 | 1567.3 MB | 48.9 MB |

观察：

1. RapidOCR 在字符层明显更好，尤其把一张重度退化 HanziPen 样张从 Vision
   的 23.58% CER 降至 3.06%。
2. 但手写总体只改善 1.56 个百分点，远低于 10 个百分点门槛。
3. Vision 的字段命中高 6.67 个百分点，说明更低 CER 不保证现有产品规则
   得到更高业务字段命中；行合并和标点差异会影响类型/日期规则。
4. RapidOCR 的内存和包体代价显著，且需要维护 iOS 前后处理适配。
5. 虚构发票两者均可读出主要数字和项目，但一期不做费用结构化，故不计分。

## 5. §5 加权评分

比较维度采用任务书规定的组内线性归一：两候选不相等时，最优得该维度满分，
最差为 0；并列均满分。延迟、包体、集成风险和活跃度直接按任务书档位计算。

| 引擎 | 手写 /35 | 打印 /25 | 字段 /15 | 风险 /10 | 延迟 /8 | 包体 /4 | 活跃 /3 | 总分 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| RapidOCR PP-OCRv5 mobile / ORT | 35.00 | 25.00 | 0.00 | 7.00 | 8.00 | 1.74 | 3.00 | **79.74** |
| Apple Vision | 0.00 | 0.00 | 15.00 | 10.00 | 8.00 | 4.00 | 3.00 | **40.00** |

按总分，RapidOCR 是分数胜者；差距大于 3 分，不触发同分风险优先规则。

### 换引擎门槛

| 必须条件 | 实测 | 是否通过 |
| --- | ---: | --- |
| 手写 CER 相对 Vision 改善 ≥10 个百分点 | 1.56 个百分点 | 否 |
| 打印 CER 不劣于 Vision 超过 1 个百分点 | 改善 3.64 个百分点 | 是 |

**两条没有同时通过，最终选定 Apple Vision。**

## 6. 集成与回归状态

- 发布实现保持 `VisionOCREngine`，标识 `apple-vision`；配置为 `.accurate`、
  `zh-Hans + en-US`、语言纠错和最小文字高度，全程本机。
- 因胜者最终不是非 Vision 引擎，按任务书 §6 不新增
  `PrimaryOCREngine`、模型 bundle、OCR DEBUG 切换器或第三方依赖。
- `OCREngine` / `TextBlock` 协议保留，未来重启选型不需要改上层录入流程。
- 新增独立 `OCRBench` 模拟器测试 scheme，不进入常规 `CareThread` scheme，
  避免每次 `verify.sh` 重跑 90 次性能采样。
- M2 当前回归基线为 Swift Testing 85/85、XCUITest 1/1；OCR 基准 XCTest
  1/1 通过。没有删除、跳过或弱化既有测试。

## 7. 局限与重启条件

### 当前产品边界

- 医生连笔处方是困难场景；本报告不承诺自动识别完美。
- App 必须保留原件、机器层与人工确认层，老人版继续采用“拍了先存、家人后补”。
- OCR 结果只用于资料整理，不提供诊断建议；低置信度和姓名错配必须要求核对。
- 真机真实病历 OCR 体感仍列入 `docs/PROGRESS.md`，不以字体模拟冒充真人手写验收。

### 何时重启

只有出现以下任一可验证变化时重启选型：

1. Paddle/RapidOCR 发布明确面向 iOS 的中文手写 mobile 套件，前后处理和
   模型可随包、无网络/遥测，且真机内存进入可接受范围。
2. 新模型在同一 P/H/D 协议上相对当时 Vision 手写 CER 改善至少 10 个百分点，
   同时打印劣化不超过 1 个百分点。
3. Apple Vision 新版本使中文手写或复杂版面能力发生实质变化，需要重建基线。
4. 有许可证清晰、≤60 MB、近 18 个月活跃且无需自维护 iOS 推理栈的中文
   手写模型。

重启仍使用本仓库虚构基准、同一评分公式和自动决策规则，不把选择留给用户。
