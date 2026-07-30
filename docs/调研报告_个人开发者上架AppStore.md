---
title: CareThread｜中国大陆个人开发者上架 App Store 资质调研
created: "2026-07-31"
policy_cutoff: "2026-07-30"
sources_checked: "2026-07-31"
scope: "本地优先、无账号、无互联网服务器、仅含用户主动附近设备迁移、无 HealthKit、无诊断/治疗建议的个人病程资料整理 iOS App"
---

# CareThread｜中国大陆个人开发者上架 App Store 资质调研

> 本报告是产品与发布决策支持，不是法律意见。政策截点为 **2026-07-30**；于 2026-07-31 联网复核官方页面，未发现 7 月 30 日至 31 日之间的相关变更。
> 本次仅公开资料调研：未注册账号、未提交申请、未付费、未操作任何 Apple 或备案账户。

## 1. 直接结论

**推荐唯一首发路线：B——中国大陆个人 Apple Developer 账号，先上架海外区并排除中国大陆；主类别选“医疗”，产品和审核备注严格限定为本地资料整理工具。**

个人署名的同类病历管理 App 目前确实存在于中国大陆 App Store，故并非事实上的“一律禁止”；但 Apple 5.1.1(ix) 不仅覆盖高监管服务，也独立覆盖“要求敏感用户信息”的 App，且没有公布个人资料工具的明确豁免，个人主体仍有 **高审核风险**。

中国大陆首发的最大平台卡点是 **有效 ICP/APP 备案号**：Apple 明示，当 App 被要求提供 ICP 备案号而没有有效号码时，无法在中国大陆上架；Apple 未公布纯离线或仅含附近迁移 App 的完整适用矩阵，官方也没有公开无域名/公共 IP App 的确定填报路径。

综合置信度：**路线 B 作为当前首发路线高（0.85）；路线 A 条件可行但当前中低（0.55）；TestFlight 适合阶段测试、不是长期发行方案（0.95）**。这些数字表示路线决策置信度，不是个人主体通过 Apple 审核的概率。

## 2. 五个问题逐一回答

### 问题一：5.1.1(ix) 对个人医疗类 App 的限制，以及 CareThread 的边界

#### 结论

**事实：** Apple 现行 5.1.1(ix) 并不是“凡是 Medical 类目都必须公司上架”，而是要求“在高监管领域提供服务”或“要求敏感用户信息”的 App 由实际提供服务的法人实体提交。条文没有给出个人健康资料工具的明确豁免清单，也没有把 App Store 类目作为唯一判断条件。

**对 CareThread 的适用判断（推断）：**

- 有利因素：无账号、无互联网服务器、无远程医生/医院服务、无诊断、无治疗或用药建议、无剂量计算、无 HealthKit；唯一直接网络能力是用户主动确认的附近 iOS 设备迁移，开发者无法访问内容。它仍属于用户管理自己资料的工具，不是医疗服务提供者。
- 风险因素：App 的核心功能要求录入姓名、病历、处方、化验和医疗影像，按 5.1.1(ix) 字面已触及敏感用户信息；新增跨设备传输也让“仅是本机文件夹”的论证变弱。OCR、指标对比和用药提醒若出现“解读、风险判断、科学用药”，还可能被认定为 healthcare service。
- 因此：在个人开发者前提下**可以尝试**，但本地处理并不是官方明确豁免；海外首发只绕开中国大陆备案门槛，不降低 Apple 的实体主体风险。外部 TestFlight 只能提供早期信号，不能当作正式上架预批准。

#### 依据原文摘录

Apple 5.1.1(ix) 的关键原文：

> “Apps that provide services in highly regulated fields … or that require sensitive user information should be submitted by a legal entity … not by an individual developer.”

省略号处是银行金融、医疗健康、博彩等示例，以及“由提供服务的实体提交”的限定。上面摘录保留了该句的两个触发条件和个人主体限制。

Apple 的审核说明页也将常见拒绝原因写为“Submitted by incorrect entity”，并说明高监管服务或敏感信息 App 应由相应法律实体提交。

#### 当前可核验的个人开发者事实参照

以下均为截至政策截点后仍可公开访问的 **中国大陆 App Store 页面**。Apple 官方说明个人账号的 App 会显示开发者个人法定姓名；这些页面的“提供者/开发者”均为自然人姓名，因此可作为个人账号事实参照，但不能证明其备案材料、历史审核理由与 CareThread 相同。

| App | 中国大陆商店页显示 | 类别 | 与 CareThread 的相似点 |
| --- | --- | --- | --- |
| [电子病历本](https://apps.apple.com/cn/app/电子病历本/id6532599282) | 提供者“琦 刘” | 医疗 | 多人病历、医院/医生/检查记录、图片识别；隐私标签“未收集数据” |
| [病历管家-掌上病历夹病历本](https://apps.apple.com/cn/app/病历管家-掌上病历夹病历本/id6452629003) | 提供者“伟 胡” | 医疗 | 病史、过敏、用药、预约、筛选和备份；隐私标签“未收集数据” |
| [健康云记录](https://apps.apple.com/cn/app/健康云记录/id6738539003) | 提供者“燕 王” | 医疗 | 病例档案、体征、趋势、用药/复诊提醒；隐私标签“未收集数据” |
| [得劲儿 - 家庭健康档案](https://apps.apple.com/cn/app/得劲儿-家庭健康档案/id6760614726) | 提供者“文苑 孔” | 医疗 | 本地加密、家庭档案、票据、提醒、指标历史；隐私标签“未收集数据” |

这些案例只证明当前中国大陆商店中存在自然人样式署名的 Medical 病历管理 App；其中部分公开描述使用 iCloud 或家庭共享，与 CareThread 的数据边界不同。App Store 隐私标签是开发者自报且页面标注未经 Apple 验证，不能作为 Apple 已确认其符合 5.1.3 或 CareThread 必然过审的证据。

#### 来源链接

- [Apple App Review Guidelines 5.1.1(ix)](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage)
- [Apple：App Review 常见问题——Submitted by incorrect entity](https://developer.apple.com/app-store/review/)
- [Apple：个人/组织会员的商店署名方式](https://developer.apple.com/support/compare-memberships/)
- 上表四个 Apple 官方 App Store 产品页

#### 明确不确定性与最快验证

Apple 没有公开更细的边界测试，最终归类由具体构建、元数据和审核员判断。**最快且不改变推荐路线的验证方式**：海外首发前先用同一构建走 TestFlight 外部测试审核；审核备注逐项声明“非医疗服务、非医疗设备、无诊断/建议/剂量计算、无账号/服务器/HealthKit、OCR 必须对照原件确认”。Beta Review 只能提供早期信号，不能保证正式审核结论；若收到 5.1.1(ix) 实体问题，则停止个人主体正式提交并转公司主体，而不是弱化或隐藏功能。

---

### 问题二：5.1.3、1.4 与本地优先存储的要求

#### 结论

CareThread 不做测量、诊断、治疗和剂量计算，因而不应触发医疗器械批准或药物剂量计算器的主体限制；但仍应遵守医疗数据敏感性、数据准确性、安全、隐私政策、个人数据共享同意和准确元数据要求。

完全本地不等于“无需隐私材料”：

1. **隐私政策 URL 仍是 iOS App 必填项**，并且 App 内也要容易访问。
2. 若最终二进制不存在服务器、中继、遥测、分析 SDK，附近迁移只把资料直接发送到用户明确选择的设备，且开发者及合作伙伴均无法访问，按 Apple “Collect”的定义可如实选择“未收集数据”。这不表示资料从不离开原设备，隐私政策仍必须披露迁移、导出和系统分享。
3. 不使用 HealthKit 不会触发 HealthKit 专属授权、用途声明和写入准确性要求。
4. 5.1.3 明确禁止把个人健康信息存入 iCloud。CareThread 不集成 iCloud Documents、CloudKit 或 iCloud KVS；对受 App 控制的健康资料目录设置并持续验证系统备份排除标记。Apple 同时说明该标记是给系统的指导而非绝对保证，因此隐私政策不能承诺“绝不会进入任何系统备份”。
5. OCR 结果只能是可编辑草稿，并持续显示“可能识别错误，请以原件为准”；指标对比只呈现事实差异，不输出好坏、风险或治疗结论。
6. 用药提醒只能复述用户录入的医嘱，不能计算剂量、推断服法或建议增减药。
7. 附近迁移会把个人健康资料共享给另一台设备，触发 5.1.2 的明确披露和许可要求：发送端必须显示目标设备、单人/全部范围、成员清单、记录/附件数量和估算大小，接收端也要确认，双端核对配对码后才传输。
8. “全部成员”可能包含未成年人。发送前应要求操作者确认有权管理和迁移所选成员资料，并在隐私政策说明监护责任，满足 5.1.4 的风险边界。

#### 依据原文摘录

Apple 1.4.1 对可能诊断或治疗、可能提供不准确数据的医疗 App 使用：

> “may be reviewed with greater scrutiny”

现行指南中，药物剂量计算器限制已经位于 **1.4.2**（不是 1.4.1）：必须来自药厂、医院、大学、保险公司、药房等获认可实体，或取得 FDA/同等监管批准。CareThread 应在需求、代码、测试和文案四层都禁止剂量计算。

Apple 5.1.3(ii) 的关键原文：

> “may not store personal health information in iCloud”

Apple 的 App Privacy Details 将 “Collect” 定义为数据被传出设备并可由开发者或第三方在实时请求所需时间之外访问；并明确只在设备上处理的数据不属于该隐私标签语境下的“收集”。

Apple 5.1.2(i) 同时要求个人数据传输/共享前明确披露共享去向并取得许可：

> “clearly disclose where personal data will be shared”

App Store Connect 对隐私政策的公开说明：

> “A privacy policy URL is required for all apps”

#### 来源链接

- [Apple《App 审核指南》中文版 1.4、5.1.1、5.1.3](https://developer.apple.com/cn/app-store/review/guidelines/)
- [Apple App Privacy Details：本机处理、Collect 定义](https://developer.apple.com/app-store/app-privacy-details/)
- [App Store Connect：Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [App Store Connect：Privacy Policy URL 为 iOS 必填](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Apple App Review Guidelines 5.1.2、5.1.4](https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing)
- [Apple：本地网络权限说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
- [Apple TN3179：Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple：`NWParameters.includePeerToPeer`](https://developer.apple.com/documentation/network/nwparameters/3020639-includepeertopeer)
- [Apple：iCloud 备份排除标记的边界](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)
- [Apple：加密出口合规概览](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Apple：`ITSAppUsesNonExemptEncryption`](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)

#### 对 CareThread 的落地判定

| 项目 | 一期判定 |
| --- | --- |
| App 隐私标签 | 最终确认无服务器/中继/遥测/分析 SDK，且附近迁移仅到用户选择设备、开发者不可访问后，可填“未收集数据”；不得据此宣称资料从不离开原设备 |
| 隐私政策 | 必须提供公开 HTTPS 静态页并在 App 内可打开；写清存储、系统备份边界、删除、导出、附近迁移、接收方、未成年人以及相机/照片/本地网络/日历权限 |
| HealthKit | 一期不接入，不声明相关能力 |
| iCloud/CloudKit | 不主动接入；Vault 和数据库设置、重设并验证备份排除标记，但不承诺系统级绝对结果；提供附近同步和用户主动加密备份 |
| 附近迁移 | `Network.framework + Bonjour + includePeerToPeer`；只在用户进入迁移页面后请求本地网络权限；双端明确确认、配对码、加密、清单与 SHA-256 校验 |
| 本地日历 | 默认用本地通知；写系统日历必须单独、明确同意，并提醒所选系统日历可能由系统账户同步；标题默认采用不暴露病名的中性文案 |
| 医疗设备声明 | 若在美国/英国/欧盟上架且主/次类别为 Medical 或 Health & Fitness，按 App Store Connect 要求完成“受监管医疗设备”声明，CareThread 如实声明不是医疗设备 |

---

### 问题三：中国大陆 App 备案、医疗类前置审批与无服务器场景

#### 结论

**个人可以作为 APP 主办者备案。** 工信部备案登记表明确允许个人姓名和身份证作为主体信息。备案通过网络接入服务提供者或 App 分发平台代为提交到主办者住所地省级通信管理局；材料齐全准确后，省级通信管理局应在 **20 个工作日**内备案。

**“医疗”App Store 类目本身不等于自动需要医疗前置审批。** 截至 2026-07-30：

- 工信部 2023 年 APP 备案通知列出的需主管部门审核文件类别是新闻、出版、教育、影视、宗教等，并未把普通个人病历整理工具列为医疗前置审批。
- 2024 年修订后的《互联网信息服务管理办法》第五条已经写为“新闻、出版、教育等”；不再逐项列出医疗保健、药品和医疗器械。
- 上海市通信管理局 2025 年官方公告说明当地相关 ICP 流程已调整，但这不能单独证明全国所有医疗健康场景都免前置要求。
- 对 CareThread 的具体判断是：未找到要求“仅由用户管理自有病程资料、无诊疗服务、无药品或医疗器械信息经营”的 App 取得医疗机构、医师或医疗器械前置许可的现行官方依据。这是基于实际服务内容的推断，不代表所有 Medical 类 App 或医疗健康互联网服务均免前置审批。

**但中国大陆可用性仍存在实质卡点。** 工信部通知的法定表述是“在中华人民共和国境内从事互联网信息服务的 APP”需要备案；无互联网服务器、只含附近点对点迁移的 App 是否落入“通过互联网向上网用户提供信息”的实体定义，存在可争论空间。Apple 当前 App Store Connect 状态文档明确写明：当 App 被要求提供 ICP 备案号而没有有效号码时，无法在中国大陆上架；但 Apple 未公开完整适用类别矩阵。对实际发布仍应把 ICP 作为路线 A 的高风险平台门槛，不能假定自动豁免。

#### 依据原文摘录

工信部 2023 年通知：

> “未履行备案手续的，不得从事APP互联网信息服务。”

同一通知还规定：

> “由其网络接入服务提供者、APP分发平台……通过备案系统……提交申请”

并明确网络接入服务提供者、分发平台需要查验“组织或个人”的真实身份和网络资源信息。

现行《互联网信息服务管理办法》第二条定义：

> “通过互联网向上网用户提供信息的服务活动。”

Apple 当前中国大陆上架状态说明：

> “App 无法在中国大陆上架，因为你尚未提供有效的……ICP 备案号。”

#### 无服务器场景的可执行判断

官方备案登记表仍包含 App 的域名列表、网络接入单位、服务器放置地和 IP 地址等字段；小程序/快应用才被明确标注为部分字段免填。现有公开官方资料没有给出“iOS 原生、无互联网服务器、仅含附近点对点迁移”的专门填表示例，也没有公开说明 Apple 如何代此类 App 提交备案。

因此当前不能诚实地承诺路线 A 一定能在无服务器状态下完成。唯一安全执行方式是：

1. **首发按路线 B 排除中国大陆，不为备案虚构服务器、域名或网络功能。**
2. 在准备中国大陆版本时，用固定书面描述同时向 Apple Developer Support、主体所在地省通信管理局和一家备案接入服务商确认：“原生 iOS；无互联网服务器、域名、公共 IP、账号或远程服务；仅在用户主动操作时使用 Bonjour 与附近 iOS 设备进行短时、加密、点对点迁移；开发者无可访问服务端；Apple 是否作为分发平台代报；域名/IP/接入字段如何如实填写。”
3. 只有得到可留存的明确路径后，才按个人主体办理真实 APP 备案；取得有效备案号并验证元数据一致后，再在同一 App 中增加中国大陆可用区。

这不是把产品选择留给用户，而是对官方公开流程缺口的风险控制：**中国大陆首发暂缓，海外首发继续。**

#### 来源链接

- [国务院/工信部：工信部信管〔2023〕105号 APP 备案通知](https://www.gov.cn/zhengce/zhengceku/202308/content_6897341.htm)
- [司法部国家行政法规库：现行《互联网信息服务管理办法》](https://xzfg.moj.gov.cn/front/law/detail?LawID=1756)
- [工信部地方通信管理局：互联网信息服务备案登记表](https://xzca.miit.gov.cn/bsfw/bszn/art/2024/art_5d3cc7f452c04fdd97b6881a20b656f9.html)
- [上海市通信管理局：2025 年优化 ICP 流程、取消相关前置审批](https://shca.miit.gov.cn/bsfw/bszn/dxsc/blcx/art/2025/art_79ee96f13cdb485b92bb4551549b5e4e.html)
- [Apple：App 信息——中国大陆 ICP 字段](https://developer.apple.com/cn/help/app-store-connect/reference/app-information/app-information/)
- [Apple：缺少/无效 ICP 备案号的上架状态](https://developer.apple.com/cn/help/app-store-connect/reference/app-information/app-and-submission-statuses)

---

### 问题四：类目选“医疗”还是“健康健美”

#### 结论

**主类别选“医疗（Medical）”，不选“健康健美（Health & Fitness）”来规避审查。** 可把“效率（Productivity）”作为次类别（若当时 App Store Connect 允许该组合），但主类别必须准确反映病历资料归档这一核心体验。

Apple 对类别的官方定义非常直接：

- Health & Fitness 面向健康生活、健身、减压和休闲活动。
- Medical 面向患者或专业人士的医学教育、信息管理和健康参考，示例明确包括 **medical record-keeping**。

CareThread 的主要对象是病历、处方、化验单、就诊资料和医嘱提醒，不是运动、冥想或一般健康生活；Medical 匹配度明显更高。

#### 依据原文摘录

Apple 对 Medical 的原文示例：

> “medical record-keeping”

Apple 同时要求类别准确反映 App 的核心体验；错误类别违反审核指南。已有个人开发者事实参照“电子病历本”“病历管家”“健康云记录”“得劲儿”均选择“医疗”。

#### 审核与备案差异

| 维度 | 医疗 Medical | 健康健美 Health & Fitness | 对 CareThread 的影响 |
| --- | --- | --- | --- |
| 类目定义 | 医学信息管理、病历记录、疾病参考 | 健身、减压、健康生活 | Medical 明显更准确 |
| Apple 审核 | 更容易触发对 1.4、5.1.3、5.1.1(ix) 的关注 | 同样属于健康数据敏感领域 | 改类目不能消除实体/隐私要求 |
| 医疗设备声明 | 在美/英/欧上架时可能要求填写 | 同样可能要求填写 | 两者没有规避差异 |
| 中国 APP 备案 | 备案看实际服务、主体和网络资源 | 同左 | 没有官方证据显示只因 App Store 类目不同就改变备案 |
| 前置资质 | 看是否实际提供受监管服务 | 同左 | CareThread 的关键是“不诊断/不治疗/不互联网医疗”，不是换标签 |

#### 来源链接

- [Apple：Choosing a Category](https://developer.apple.com/app-store/categories/)
- [Apple：App Information——Regulated Medical Devices 声明适用范围](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- 问题一列出的同类中国大陆 App Store 页面

---

### 问题五：个人账号注册、费用、署名、协作与未来转公司

#### 结论

中国大陆个人可以注册 Apple Developer Program。基本条件是：

- 达到所在地法定成年年龄；
- Apple 账户开启双重认证，账户身份信息真实、最新；
- 使用 Apple Developer App 注册时，需要受支持设备、iCloud 登录、身份证号、电话和自拍身份验证；
- 个人法定姓名会作为 App Store 的供应商/开发者名称显示；
- 中国大陆 Apple Developer App 当前显示 **每年 ¥688 自动续订**；Apple 全球说明为 **99 美元/会员年或当地货币**。

本次调研没有执行注册或付费。

#### 个人与组织账号差异

| 事项 | 个人账号 | 组织账号 |
| --- | --- | --- |
| 商店署名 | 个人法定姓名 | 法人实体名称 |
| 注册主体材料 | 个人身份验证 | 法人资格、D‑U‑N‑S、签约授权、工作邮箱、公开组织网站 |
| 协作 | 最多给 50 名额外用户 App Store Connect 内容权限；他们不是 Developer Program 团队成员 | 可把成员加入完整团队，按角色访问开发与分发资源 |
| App 转移 | 可作为转出/接收账号，前提是 App 和双方账号满足转移条件 | 同左 |
| 直接转组织 | Apple 官方说明可联系支持申请把个人会员转为组织 | 需要组织验证 |
| 署名连续性 | 转移后供应商变为接收方；App 可保留 Bundle ID、评分和评论（满足条件时） | 同左 |

#### 依据原文摘录

Apple 对个人账号署名的原文：

> “Apps are listed under the developer’s personal name.”

Apple 对年费的原文：

> “99 USD … per membership year.”

中国大陆注册页明确写明个人法定姓名将作为供应商展示，并显示“以每年 ¥688 续订”。

#### 为未来公司主体预留的确定做法

1. Bundle ID、App 名称、隐私域名、代码签名和知识产权从一开始保留清晰归属记录。
2. 不把 CloudKit 容器、App Group、钥匙串访问组等难转移能力引入一期；转移前按 Apple transfer criteria 逐项复核。
3. 公司成立并通过 Apple 组织验证后，优先评估“个人会员转组织”；若不适用，再走 App Transfer。
4. App Transfer 要求至少已有一个正式发布版本，并且双方协议有效、App 不处于审核/预购等禁止状态；转移前还要关闭 TestFlight、处理 Xcode Cloud 等数据。

#### 来源链接

- [Apple：中国大陆使用 Apple Developer App 注册](https://developer.apple.com/cn/help/account/membership/enrolling-in-the-app/)
- [Apple：Program Enrollment](https://developer.apple.com/help/account/membership/program-enrollment)
- [Apple：Choosing a Membership](https://developer.apple.com/support/compare-memberships/)
- [Apple：个人账号与组织账号的用户协作差异](https://developer.apple.com/help/app-store-connect/manage-your-team/add-and-edit-users)
- [Apple：App Transfer 概览](https://developer.apple.com/help/app-store-connect/transfer-an-app/overview-of-app-transfer/)
- [Apple：App Transfer Criteria](https://developer.apple.com/help/app-store-connect/transfer-an-app/app-transfer-criteria)

## 3. 三条路线对比与推荐

| 路线 | 法规/审核可行性 | 主要卡点 | 周期口径 | 国内用户实际获取 | 风险 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| **A. 个人账号直接上架中国区** | 不是绝对禁止；已有个人同类事实参照。须同时过 Apple 实体判断和中国大陆备案门槛 | 无互联网服务器、仅含附近迁移的 APP 备案公开流程不清；被要求提供 ICP 时缺有效号码即不在中国大陆提供 | 备案材料完整后官方审查上限 20 工作日；总体按 4–8 周以上规划仅是项目估算，适用路径未确认时可能更久 | 中国大陆区 Apple 账户可直接下载 | 高 | **不作为一期首发** |
| **B. 个人账号仅上架海外区** | 合法使用 App Store Connect 的地区可用性设置；不在中国大陆提供，就不触发 Apple 的中国大陆 ICP 上架字段 | 仍需过 5.1.1(ix)、1.4、5.1.2、隐私与元数据审核；美/英/欧可能需医疗设备状态声明 | 预留 2–4 周为项目估算，Apple 不承诺固定审核期 | 中国大陆区 Apple 账户无法搜索/购买；账户所属地区决定可用商店。切区常受余额、订阅、支付方式、家庭共享限制，不应作为普通用户路径 | 中高 | **唯一推荐首发路线** |
| **C. 不上架，仅 TestFlight** | 必须是 Developer Program 会员；Beta 也要遵守审核指南。外部组首个构建要 TestFlight App Review，重大更新也可能复审 | 构建 90 天到期，需要持续上传；不是永久安装渠道 | 内部测试可快速开始；外部首构建等待审核，时间不承诺 | 受邀用户需 TestFlight；不形成可持续公开产品 | 低到中 | **只作上架前测试，不替代 B** |

### TestFlight 的明确限制

- 单个构建最多测试 **90 天**。
- 外部测试员最多 **10,000**；内部测试员平台上限 **100 名 App Store Connect 用户**。
- 个人会员最多只能额外给 **50 人** App Store Connect 内容权限；连同 Account Holder，个人账号理论上约 **51 名**内部测试员，且都必须具备适当职能和 App 内容访问权限。
- 外部组的第一个构建需要审核；后续构建可能不需要完整审核，但重大更新应提交 Beta Review。
- TestFlight 适合家人朋友验证相机、Face ID、提醒和老人版，不适合长期交付。

来源：

- [Apple：TestFlight Overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [Apple App Review Guidelines 2.2 Beta Testing](https://developer.apple.com/app-store/review/guidelines/#beta-testing)
- [Apple：地区可用性由用户 Apple Account 国家/地区决定](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-for-your-app-on-the-app-store)
- [Apple Support：切换 Apple Account 国家或地区的限制](https://support.apple.com/118283)

## 4. 对产品设计的反向要求

### 4.1 必须保持的产品边界

- 不接医院、医生、药房、保险、云端或第三方 AI 服务；零互联网请求、零业务服务器、零第三方联网 SDK。
- 唯一直接网络白名单是用户主动进入的 iOS 附近迁移：使用 `Network.framework`、Bonjour 与本地/点对点链路，传输到用户选定的另一台 CareThread 设备，不经过开发者服务器。
- 不提供问诊、诊断、风险分级、治疗建议、用药建议、剂量计算或指标“正常/异常”自动结论。
- OCR 只做转录草稿；任何姓名、医院、医生、药品、剂量、指标都由用户确认，原图始终可回看。
- 多成员只表示同一设备上的独立家庭档案，不叫“多用户账号”，不产生登录、共享或远程协作语义。
- 指标对比只输出两个期间的原始值、差值、方向和数据缺失说明，不输出疾病判断。
- 用药/复查提醒只复述用户输入；系统通知默认使用中性标题，锁屏不泄露病名或药名。
- 不使用 iCloud Documents、CloudKit 或 iCloud KVS；数据库、原件 Vault、临时导出和缓存均纳入数据保护，对受 App 控制的健康资料持续设置并验证系统备份排除标记，不承诺系统级绝对结果。
- 附近迁移发送端显示目标设备、单人/全部范围、具体成员、记录/附件数量和估算大小；接收端再次确认，双端配对码一致后才开始。
- 选择未成年人档案时，发送者确认自己有权管理和迁移；产品不使用“儿童专用/For Kids”定位。

### 4.2 隐私政策静态页

即使 App 无互联网服务器且开发者不收集数据，也必须准备公开 HTTPS 页面。最低包含：

- 开发者身份和联系邮箱；
- 明确“无账号、无广告、无分析 SDK、无互联网服务器、无 HealthKit”；除用户主动导出、系统分享、日历写入和附近设备迁移外，业务数据不离开本机；
- 照片、相机、Face ID、通知、本地网络、Bonjour 和日历权限的用途和可拒绝后果；
- 数据存放、文件保护、删除单条记录/成员/全部数据的方法；
- 用户主动导出、系统分享和写入系统日历可能把内容交给用户选择的第三方 App/系统账户；
- 附近设备迁移只在两台设备分别确认后，把单个或全部成员档案直接发送到用户选定的另一台 iPhone；不经过开发者服务器，开发者无法访问；
- 监护人或资料管理者应确保有权录入、导出和迁移所选成员（包括未成年人）的资料；
- 不集成 iCloud/CloudKit；App 会对受控健康资料设置系统备份排除，但 Apple 不保证系统备份/恢复的绝对行为；
- OCR 可能错误，必须以原始文件和医生意见为准；
- 政策版本号、更新时间、适用 App 版本。

这个静态页是 App Store 元数据资源，不要求 App 在运行时联网；App 内可用内置同版隐私文本，并提供外部 URL。

本地网络权限建议文案：

> CareThread 仅在你主动迁移数据时，通过附近网络发现另一台 iPhone，并直接传输你选择的家庭健康档案；数据不经过开发者服务器。

### 4.3 App Store 文案

建议标题/副标题：

- 名称：`CareThread`
- 副标题：`本地病程资料整理与提醒`

避免使用：

- “智能诊断”“专业解读”“科学用药”“发现风险”“健康守护者”“临床决策”
- “电子病历系统”（容易被理解为医疗机构 EMR）
- “绝对安全”“永不丢失”“医疗级准确”

建议产品页首段：

> CareThread 是一款在 iPhone 本机整理本人及家人病程资料的工具。它没有账号或云端服务器；只有在你主动确认时，才会把所选资料加密直传到附近的另一台 iPhone。它不连接医院，不提供诊断、治疗或用药建议。OCR 内容可能有误，请始终对照原始资料并咨询医疗专业人员。

### 4.4 审核备注模板

```text
CareThread is a private, local-first document organization tool.
It does not provide healthcare services, diagnosis, treatment recommendations,
drug dosage calculations, or clinical decision support.

There is no account, backend, analytics, advertising, HealthKit, CloudKit,
or developer-accessible data collection.

Its only direct networking feature is optional, user-initiated nearby-device
migration. It uses Network.framework and Bonjour solely to discover another
CareThread device on local or peer-to-peer interfaces. A transfer requires
explicit approval on both devices and a verified pairing code, is encrypted
in transit, and can include either one selected family member or all members.
It never uses an Internet relay or developer server, and the developer cannot
access the transferred health data.

Except for a user-initiated nearby transfer, export, system share, or calendar
write, medical documents and OCR results remain on the originating device.
OCR is only an editable transcription draft; users are required to verify it
against the original document.

Medication and follow-up reminders only repeat information manually entered
by the user. Comparisons display historical values and differences only.
The app clearly tells users to consult qualified clinicians before making
medical decisions.
```

### 4.5 截图与审核演示

- 截图中全部使用虚构姓名、医院、医生和病历，不放真实健康信息。
- 首屏和 OCR 确认页可见“资料整理工具/以原件为准”，不要只藏在设置页。
- 展示姓名不匹配的硬拦截和二次确认，证明不会把资料静默归错成员。
- 展示原件回看、数据删除、本地导出和权限拒绝后的替代路径。
- 展示“设置 → 附近同步/换机 → 单个成员/全部成员 → 双端配对码 → 双端确认 → 数量与完整性校验”。审核备注说明该路径需要两台安装 CareThread 的 iOS 设备，并提供录屏；不提供隐藏绕过。
- 审核构建不得含占位隐私 URL、隐藏云功能、远程配置或未说明的联网 SDK。

## 5. 行动清单

### 现在就能做的（无需开发者账号、无需备案申请）

1. 将一期发布范围锁定为 **路线 B：海外区首发，排除中国大陆**。
2. 主类别锁定为 **Medical**；产品定位固定为“本地资料整理”，不再出现诊断/解读/建议话术。
3. 在代码验收中加入零互联网端点、零业务服务器、零第三方联网 SDK、零 HealthKit/CloudKit、系统备份排除复核；Network.framework/Bonjour 只允许出现在附近迁移模块。
4. 完成隐私政策和支持页静态稿；准备公开 HTTPS 托管，但不写任何个人健康数据。
5. 将上面的审核备注模板、虚构演示数据和权限说明纳入上架材料。
6. 把“系统日历可能由系统账户同步”的独立同意和中性提醒标题纳入验收。
7. 为附近迁移加入本地网络用途文案与 `_carethread._tcp` Bonjour 声明；权限只在用户进入迁移功能时触发。
8. 使用 Apple 系统 Security/CryptoKit 能力，上架前按最终实现完成加密出口合规问卷，并根据问卷结果设置 `ITSAppUsesNonExemptEncryption`，不预先猜测答案。

### 上架前一个月

1. 重新检查最新版 App Review Guidelines、App Store Connect 中国大陆字段和受监管医疗设备声明；本报告不能替代提交时的动态复核。
2. 进行真机验证：相机、照片权限、Face ID、通知、日历、系统分享、微信分享入口、老人版。
3. 用外部 TestFlight 首构建验证 5.1.1(ix) 实体判断和医疗定位；Beta 审核反馈原样留档。
4. 若仍计划随后开放中国大陆，用本报告第 3 题的固定描述做三方书面咨询；只有得到如实备案路径后才进入办理。
5. 准备 App 隐私答案、内容分级、非医疗设备声明和支持联系方式。
6. 用两台真机录制附近迁移完整路径，验证本地网络权限拒绝、配对码、单人/全部、断线、取消和校验；确认“未收集数据”结论仍符合最终二进制。

### 正式提交时

1. App Store Connect 可用地区选择海外目标区，明确取消 **China mainland**。
2. App Privacy 在确认最终二进制后如实选择“未收集数据”，填写公开隐私政策 URL。
3. 主类别选 Medical；如目标地区出现 Regulated Medical Devices 字段，如实声明非医疗设备。
4. 粘贴完整审核备注；提供从首次启动到添加虚构病历、OCR 确认、提醒、导出、删除的可复现步骤。
5. 审核若引用 5.1.1(ix)，只围绕已公开的本地工具边界申诉一次；若仍要求法人实体，停止个人正式上架尝试，转公司主体，不通过改名、隐藏功能或错误分类规避。
6. 海外版本稳定后，只有在取得有效 APP 备案号并确认 Apple 元数据匹配时，才增加中国大陆可用区。
7. 如实完成加密出口合规问卷；在审核备注给出附近迁移的双机步骤、权限、配对、加密、接收范围和无服务器说明。

## 6. 剩余不确定项登记

| 不确定项 | 为什么不能从公开官方资料消除 | 最快验证方法 | 不改变的当前决策 |
| --- | --- | --- | --- |
| Apple 是否把 CareThread 认定为 5.1.1(ix) 的 healthcare service | 指南没有个人资料工具的明确定义或预批准清单 | 同一构建走外部 TestFlight 审核，审核备注完整披露 | 仍按路线 B；若要求实体则转组织 |
| 无互联网服务器、仅含附近点对点迁移的 iOS App 如何取得 APP 备案号 | 公开登记表含网络资源字段；未找到 Apple/工信部针对该形态的完整适用矩阵和填表示例 | Apple Support + 属地通信管理局 + 备案接入商书面确认 | 不开放中国大陆，不虚构网络资源 |
| 同类个人 App 的具体备案/审核历史 | 商店页只证明当前供应商、类别和可用性，不公开提交材料 | 不依赖其历史；必要时查看产品页备案号并向主管系统核验 | 只作事实参照，不作通过承诺 |
| 审核和备案总周期 | Apple 审核无固定承诺；接入商预审时长不统一 | 上架前以当前官方状态和接入商 SLA 更新排期 | 路线 B 预留 2–4 周，A 预留 4–8 周以上，均为项目估算 |

## 7. 最终执行建议

CareThread 一期应继续以 **纯原生 iOS、本地优先且无互联网服务器、仅含用户主动附近直传、Medical 类目、个人法定姓名署名、海外区公开上架**为目标；TestFlight 只用于真实设备和审核边界验证。中国大陆区不与一期首发绑定，也不为了备案引入伪服务器或削弱隐私承诺。取得可复核的备案适用结论、如需则取得有效备案号后，再通过 App Store Connect 增加中国大陆可用性；若 Apple 对同一构建明确要求法人实体，则直接转公司主体，不做规避式修改。
