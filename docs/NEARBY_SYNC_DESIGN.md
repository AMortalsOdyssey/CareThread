# CareThread iOS 附近同步与换机设计

## 1. 唯一技术路线

一期采用 Apple 原生 `Network.framework`：

- `NWListener` 在“接收资料”页面临时监听并发布 Bonjour 服务。
- `NWBrowser` 在“发送资料”页面临时发现附近 CareThread 设备。
- `NWParameters.includePeerToPeer = true` 允许系统选择本地网络和 Apple 点对点链路。
- 业务协议使用 P256 临时密钥协商、HKDF 派生会话密钥、六位短认证码（SAS）双端比对，以及逐块 AEAD 加密。
- 不访问互联网端点，不创建服务器，不需要 CareThread 账号。

不以 `MultipeerConnectivity` 作为新实现。Apple 当前文档已将其核心浏览、广告和会话 API 标记为 Deprecated，并写明 “Use Network Framework instead”。Apple 同时把 Network framework描述为 Apple 平台低层连接的推荐方案，并提供 Bonjour 浏览、监听和 peer-to-peer 参数。

官方依据：

- [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity/)：旧框架支持 Wi‑Fi、peer-to-peer Wi‑Fi 与 Bluetooth，但当前符号已标记弃用并指向 Network framework。
- [`NWParameters.includePeerToPeer`](https://developer.apple.com/documentation/network/nwparameters/3020639-includepeertopeer)：Apple 原文为 “enables peer-to-peer link technologies for connections and listeners”。
- [Use structured concurrency with Network framework](https://developer.apple.com/videos/play/wwdc2025/250/)：Apple 将 Network framework描述为 Apple 平台低层网络连接的最佳方式，并展示浏览和监听。
- [Support local network privacy in your app](https://developer.apple.com/videos/play/wwdc2020/10110/)：Bonjour/本地网络功能必须提供本地网络用途说明和声明服务类型。

AirDrop 只作为“导出备份包 → 系统分享”的人工兜底。它不能提供 App 内对接收端事务、断点、冲突、进度与完整性结果的同等控制，因此不作为主动同步主线。

系统 Quick Start/整机恢复保留为 iOS 自身能力，但不计入 CareThread 的数据可达承诺。Apple 的 [`isExcludedFromBackup`](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey) 文档将其定义为从 App 数据备份中排除资源；[iCloud 备份优化说明](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup) 又明确指出该标记只是给系统的排除指示，不能保证文件一定不会出现在备份或恢复设备上。CareThread 为遵守医疗数据不写入 iCloud 的审核边界，需要对真实 Vault 和数据库执行备份排除，因此不能同时承诺 Quick Start 一定包含这些资料。附近同步和用户主动加密备份才是可校验的正式迁移路径。

## 2. 产品定义

入口名称为“附近同步/换机”，不是持续云同步。

发送端：

1. 选择“单个成员”或“全部成员”。
2. 生成一致性快照和预检摘要：成员、记录、附件数量与总字节数。
3. 临时搜索附近设备，选择只显示随机会话代号的目标。
4. 双端比对同一六位配对码并各自确认。
5. 传输，显示总进度、当前文件、剩余量和取消。
6. 等待接收端完整校验并事务提交后显示成功。

接收端：

1. 点击“接收资料”后才请求本地网络权限并开始广播。
2. 收到邀请后显示来源随机代号和传输摘要；不在发现阶段展示成员姓名。
3. 比对配对码并确认。
4. 预检 App/协议版本、空间、成员上限和冲突。
5. 写入受保护 staging；全部哈希和引用通过后一次性导入。
6. 失败时保持现有库不变，并可按传输 ID 恢复安全的未完成分块。

## 3. “同步”的范围

一期实现用户主动触发的设备到设备快照同步，可重复执行；不是两台设备后台实时双向同步。

- 单成员：只传该成员的结构化数据、原件、提醒定义和审计。
- 全部成员：传所有成员，但仍逐成员生成独立清单和哈希树。
- 相同 UUID + 相同内容哈希：幂等跳过。
- 相同 UUID + 不同内容：绝不静默覆盖。换机空设备可在预检后整体导入；已有数据设备进入冲突摘要，默认保留接收端并允许用户显式选择以来源快照替换相关成员。
- 删除不会通过一期主动同步传播为远端删除，避免旧设备误删新设备资料。

## 4. 安全协议

- Bonjour 服务：`_carethread._tcp`；TXT 只包含协议主版本和能力位，不含设备真实名称、成员姓名、记录数或文件名。
- 会话显示名：每次进入页面生成随机、短期代号，退出即失效。
- 连接后双方生成新的 P256 临时密钥，交换公钥和 nonce。
- 双方以 ECDH 共享秘密 + 两端 nonce + transfer ID 经 HKDF 派生：
  - 六位 SAS 配对码；
  - chunk AEAD 密钥；
  - manifest 认证密钥。
- 用户在两台设备看到相同 SAS 并确认后才发送敏感清单。代码不同立即取消，可防附近误连；密钥每次会话更换。
- 每块密文的 authenticated data 绑定协议版本、transfer ID、file ID、sequence、offset 和明文长度；篡改、跨文件替换、重放到错误偏移均失败。
- 原件最终使用 manifest 的 SHA-256、字节数与业务引用复核；清单本身有会话认证。
- 临时密钥不持久化；接收 staging、resume journal 和导入事务均受 Data Protection。
- 日志只记录传输 ID 的截断摘要、状态、计数、字节和错误码，不记录姓名、路径、清单正文或密钥。

## 5. 分块、恢复与资源

- 默认 chunk 64 KiB，边读边加密发送，边收边解密写文件；禁止把 250 MiB PDF 或全部备份读成单个 `Data`。
- 单文件按 `fileId + sequence + offset` 持久化安全 checkpoint。重复收到已验证块时返回幂等确认；跳号或重叠范围拒绝。
- 断线后双方重新发现、重新配对并建立新会话密钥；接收端只根据已落盘且哈希/长度正确的 checkpoint 报告缺失范围。
- 取消停止浏览、监听和 I/O，在 500 ms 内进入取消态；staging 按过期策略清理。
- `includePeerToPeer` 只在同步界面开启。Apple 提醒 peer-to-peer 链路更耗电，不能后台常驻；重试采用指数退避。

## 6. 权限与文案

`Info.plist` 需要：

- `NSLocalNetworkUsageDescription`：用于在用户主动选择时发现附近 iPhone 并加密迁移 CareThread 资料；不会连接互联网。
- `NSBonjourServices`：`_carethread._tcp`。

拒绝权限时仍可通过“导出加密备份包 → AirDrop/文件 → 在接收端选择导入”完成手动迁移，其他病程功能不受影响。

## 7. 自动化方案

不依赖无线电的确定性测试：

- 单成员/全部清单、稳定 JSON 和版本拒绝。
- P256/HKDF 两端同密钥同 SAS，错误公钥不同。
- chunk AEAD、AAD 篡改、错密钥、乱序、重复和 resume。
- manifest/逐文件哈希、空间不足、成员上限、冲突、取消和事务回滚。
- 25 MiB/250 MiB 稀疏或生成文件的流式峰值内存与磁盘故障注入。
- 两个独立临时 Vault 完成端到端导出→传输→校验→导入，复核单成员/全部及跨成员零泄漏。
- `NWConnection` 抽象使用 in-memory transport 做丢包、断线、重复和延迟注入。

当前环境尽力补充：

- 同一 Mac 上启动两个 iOS Simulator，验证 Bonjour 权限、发现、连接、配对和小包往返。
- 若模拟器不支持特定 peer-to-peer 路径，保留真实执行日志并不伪造 PASS。

最终双真机：

- 同一 Wi‑Fi、无共同路由器的点对点场景、锁屏/回前台、网络切换、长文件断线恢复。
- 单成员与全部成员、接收端已有数据、空间不足、权限拒绝和用户取消。
