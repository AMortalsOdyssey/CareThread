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
- 相同 UUID + 不同内容：V1 整个导入事务失败，绝不静默覆盖、重映射或提供“强制替换”。用户需要先导出冲突摘要并整理接收端数据，再重新发起传输。
- 删除不会通过一期主动同步传播为远端删除，避免旧设备误删新设备资料。

## 4. 安全协议

- Bonjour 服务：`_carethread._tcp`；V1 的 TXT 为 `nil`，不含协议能力以外的任何可观察业务数据，更不含设备真实名称、成员姓名、记录数或文件名。
- 会话显示名：每次进入页面生成随机、短期代号，退出即失效。
- 连接后双方生成新的 P256 临时密钥，交换公钥和 nonce。
- 双方以 ECDH 共享秘密 + 两端 nonce + transfer ID 经 HKDF 派生：
  - 六位 SAS 配对码；
  - chunk AEAD 密钥；
  - manifest AEAD 密钥。
- 用户在两台设备看到相同 SAS 并确认后才发送敏感清单。代码不同立即取消，可防附近误连；密钥每次会话更换。
- 每块密文的 authenticated data 绑定协议版本、transfer ID、file ID、sequence、offset 和明文长度；篡改、跨文件替换、重放到错误偏移均失败。
- manifest 本身使用 ChaChaPoly 加密；AAD 固定绑定 `v1 + sessionID + transferID + keyEpoch + direction + manifest`。网络上不会出现可直接 JSON 解码的明文清单。
- V1 domain payload 使用按实体类型固定的 required/allowed fields；根对象与嵌套对象都拒绝未知 key。`Attachment` 必须同时引用同成员 `MedicalRecord` 和唯一 `originalFileID`，原文件 descriptor 必须反向声明唯一 `ownerAttachmentID`；所有引用必须闭包且不允许 orphan。
- 原件最终使用 manifest 的 SHA-256、字节数与双向业务引用复核；清单密文、摘要和上下文全部通过后才签发 `VerifiedTransfer`。
- 临时密钥不持久化；接收 staging、resume journal 和导入事务均使用 `.complete` Data Protection，并从系统备份排除。
- 日志只记录传输 ID 的截断摘要、状态、计数、字节和错误码，不记录姓名、路径、清单正文或密钥。

## 5. 分块、恢复与资源

- 默认 chunk 64 KiB，边读边加密发送，边收边解密写文件；禁止把 250 MiB PDF 或全部备份读成单个 `Data`。
- 单文件按 `fileId + sequence + offset` 持久化安全 checkpoint。每 8 块或文件末尾批量同步 checkpoint，避免每块 `fsync`；崩溃恢复只信任最后持久化位置并截断其后的未确认字节。重复收到已验证块时返回幂等确认；跳号或重叠范围拒绝。
- wire parser 使用固定 V1 头和消息分类，在读取声明的 payload 前应用 control/handshake/manifest/chunk/receipt 各自上限；同时限制连接帧数、累计字节、单次输出和解析缓冲区。合法的 TCP 分段与合并均可增量解析。
- staging 默认总预留上限 4 GiB，并在建立文件前检查重要用途可用空间，至少保留 256 MiB；取消只按本地 `transferID` capability 清理，绝不解析远端路径。
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

已落地的 primitive 测试还覆盖：

- manifest 密文不可 JSON 解码，AAD 的方向、epoch 或密文任一位变化都会在解码前失败。
- 严格嵌套 keys、typed V1 fields、`RecordTag`/`ContentRevision`、原件反向 owner、orphan/多认领与 UUID 内容冲突。
- 任意逐字节 TCP 分段、合法合并帧、错误 wire 版本、分类超长、接收 segment 超长。
- `SecRandomCopyBytes` 失败即停止会话，不使用全零或伪随机 nonce。
- staging quota、作用域清理、`.complete` 保护、提交结果与认证 receipt 跨启动幂等恢复。

当前生产接线已经完成：

- `NearbySyncFlowHost` 提供发送/接收、单成员/全部成员、随机会话代号、附近设备选择、双端六位 SAS、清单预览、用户确认、进度、取消、成功和可恢复错误状态。
- `NearbySyncExporter` 从 SwiftData 与 Vault 生成版本化领域 envelope、关系闭包、实体指纹和原件 descriptor；不会把成员姓名写入 Bonjour 元数据。
- `NearbySyncCoordinator` 在 `NearbyByteTransport` 上完成 bootstrap、P256 握手、双方 key-confirmation、加密 manifest、resume 查询、逐块传输和认证提交回执。
- `NearbySyncReceiverPreflight` 与 `NearbySyncImporter` 只接受 `VerifiedTransfer`，预检成员上限、空间、UUID 冲突和引用闭包；原件先进入事务目录，数据库保存成功后才提交 Vault，失败回滚。
- `NearbySyncFlowController` 管理真实 `NWBrowser` / `NWListener` 生命周期，页面退出、进入后台或用户取消都会停止浏览、监听和连接。

自动化已覆盖协议原语、完整协调器、领域导出/导入、事务回滚、单成员/全部成员、幂等重试、冲突拒绝、流式分块和生产 UI 流。模拟器只能确定性验证可注入传输、文件系统、SwiftData 事务和界面状态；两台真实 iPhone 的 Bonjour 无线发现、点对点链路、锁屏/回前台与 Wi‑Fi/蓝牙切换仍保留在最终真机清单，不能用模拟 transport 的通过结果替代。

建议加入 `acceptance.sh` 的静态扫描：

- `NWConnection`、`NWListener`、`NWBrowser` 只能出现在 `Core/Services/NearbyTransfer`；全仓继续拒绝 `URLSession`、WebSocket、CloudKit、MultipeerConnectivity 和第三方网络 SDK。
- Nearby 出站连接只能接收 `NearbyDiscoveredPeer` capability；拒绝业务代码出现 `.hostPort`、IP 字面量、远端域名和任意端口初始化。
- `Info.plist` 必须同时包含 `NSLocalNetworkUsageDescription` 与 `_carethread._tcp`，Bonjour TXT 必须为 `nil`。
- manifest 必须出现 `ChaChaPoly.seal/open` 和 `TransferManifestAAD`，不得回退到明文 JSON + HMAC。
- `SecRandomCopyBytes` 调用必须检查 `errSecSuccess`；拒绝忽略返回值、`arc4random`、固定 nonce 或全零降级。
- staging 保护必须为 `.complete`；拒绝 `.completeUntilFirstUserAuthentication`、未排除备份和把远端 `relativePath` 拼接为本地路径。
- 原件流不得使用无上限的 `Data(contentsOf:)`；domain envelope 的一次性读取上限必须不高于 256 KiB。
- wire 层必须经过 `IncrementalNearbyWireParser` 的分类上限；拒绝直接信任远端长度后分配、无界 `AsyncStream` 或无界发送等待队列。
- commit importer 的调用点必须只接受 `VerifiedTransfer`，并显式使用 `transferID` 作为幂等键；拒绝对 UUID 冲突做覆盖或静默重映射。

当前环境尽力补充：

- 同一 Mac 上启动两个 iOS Simulator，验证 Bonjour 权限、发现、连接、配对和小包往返。
- 若模拟器不支持特定 peer-to-peer 路径，保留真实执行日志并不伪造 PASS。

最终双真机：

- 同一 Wi‑Fi、无共同路由器的点对点场景、锁屏/回前台、网络切换、长文件断线恢复。
- 单成员与全部成员、接收端已有数据、空间不足、权限拒绝和用户取消。
