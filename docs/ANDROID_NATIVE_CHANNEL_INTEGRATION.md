# Android 原生入口联合候选

2026-10-04 UTC。本片基于 core `c5866f59299cbb6838c3f753dda7aaefeb7fcf82`、mobile `b3daffee31c45d1a31257911651e6bc04fa7f9d4` 的纯公开归档，只覆盖冻结的邮件 Go helper 与本合同列出的 Kotlin/host 源；不修改 Flutter、服务器或协议。当前为候选，尚未执行联合 SDK 或 Flutter P1/P2/P3 产品流程，不开放默认逐项验收集合。

## 公共入口

固定 Channel 为 `org.harmoniavault/native/v1`。`executeDAGRecovery` 精确接收 `{command:String,completeCode:Uint8List}`；参数解析、代码字节数和操作字段仍由成熟 Go Validate 约束，原生 epoch、scope、registry、CA、文件路径与钥匙不接受 Dart 提供。每次业务操作重新系统设备密码或强生物 CryptoObject 认证，再新建 AtomicWorkflow；跨次只保留 typed RAM registry。`dagWorkflowProfile` 仅 null 参数，返回真实 Go 的独立 DAG String JSON；不复用普通 workflowProfile、不包含平台本地 cancel。

`executePendingPairings` 精确接收 `{command:String}`，复用已冻结 pending dispatcher：当次强认证 → fresh Atomic provider → 成熟 Go Boot/Pull/GET/postcheck。元数据不是批准权限；失效/取消或 close 不明不能返回成功列表。

P3 七动作保持固定 ABI：

| 方法 | 精确参数 | 返回 |
| --- | --- | --- |
| requestAccountResetEmail | `{endpoint:String,email:Uint8List}` | 成熟 Go accepted JSON，trustedDevice=false |
| beginAccountReset | `{endpoint:String,proof:Uint8List}` | 原证明 Query outcome JSON |
| beginAccountResetQueryOnly | 同上 | 查询专用 outcome，不能 prepare/complete |
| queryAccountReset | null | 同 RAM 原证明/原事务查询 |
| prepareAccountReset | `{password:Uint8List,confirmation:String}` | confirmation 精确 DELETE_OLD_VAULT；prepared JSON |
| completeAccountReset | null | 原 Query/旧槽认证与排空、清理核验后成熟 Go outcome |
| cancelAccountReset | null | 邮件与 reset 自己的 worker 确认排空后 null；只是本地退休 |

邮箱 UTF-8 1–320 bytes，拒绝 NUL/CR/LF；proof 1–4096 bytes；密码 1–16384 bytes。所有通道秘密字节先复制并消费传入缓冲，内部副本转交 owner 后由其 finally 清理，格式失败和已关闭分支也消费；不声称清除 Go/JNI/VM 的所有运行时副本。proof/密码语义、账号与代际仍由成熟 Go 判定，不拼装 raw signing/proof 或返回 bearer。邮件申请只用 RAM HTTP owner；accepted 不确认账号存在、送达或设备信任。

## 服务范围的两个原生来源

现有 instance-info inspection 在 Dart 的局部严格 HTTPS 客户端中；本片不把 UI 声明或公开 validateEndpoint 当成已检查服务身份。native RAM 受控 endpoint 来源有两种：成功的成熟 OpenAtomicWorkflow（包括 ordinary/DAG/pending）记录其 endpoint；冷状态暂无这种来源时，第一次 P3 mail/begin 先通过 Go canonical HTTPS 地址校验，再固定该 flow 地址。后者只固定范围，不授信任，不假称已完成 inspection。

BUSY 在 canonical 校验与首次 claim 之前拒绝，不能让未获执行的 P3 请求改变正在等待认证的 opener 地址。后续 P3 与敏感 native intent 必须与已固定 endpoint 精确相同，不同地址在新认证/网络前拒绝；CA 只由原生构造器注入。后台退休保留地址，不能隐式换服。P3 cancel 仅在自己的 mail/reset 排空、ordinary worker 未占用、DAG 无 RAM owner/操作/取消排空、pending 已结束时释放 P3-only 范围；它不能释放由 ordinary Atomic opener 建立的范围。正式普通 logout 的成熟结果 ok=true、旧槽已释放且所有 owner fence 完成后，才释放后者。dispose 永久退休该 scope；迟到 opener 不能复活。地址不写磁盘，本片未新增 URL prefs。

## 排空与删除

普通/PIN、DAG、pending、mail、reset 的在途操作相互 BUSY。邮件或 pending 的取消先撤销当前 ctx/票，再等待自己的 worker finally 关闭；新任务不能在 drain 中插入。reset 的 authoritative Query 成功后，再逐项等待 pending/mail、普通 worker 队列 fence（先前 finally 和 recoveryRegistry 清钥已结束）、DAG registry Close 与 slot release。任一排空失败不执行后续本机旧槽清理。旧槽 AEAD binding、完整 captured snapshot/epoch、PIN/混合残留拒绝、真正 CryptoObject 和 fresh empty slot 核验沿用公开 dispatcher，不靠调用方 cleanup bool。

DAG对外admission BUSY同时包含活动operation、显式取消等待和后台registry Close的精确drain票；worker Close完毕仍需main确认才能释放。内部operationActive/可完成cancel条件分开，空cancel也走队列fence，dispose不会因取消等待产生自锁。Close不明永久BUSY，取消只返回固定失败。

所有排空动作分别尝试；close 不明粘性阻断后续提交/交付，不能下一 operation epoch 自动恢复。重复 cancel 的 BUSY 不被伪装为已清理。cancelAccountReset 只排空自己的 mail/reset，不称服务器取消或物理删除。logout 在交付前增加同一 owner fence；底层合法只读与 unknown 原 ID 语义不改。

## 能力与实际证据

capabilities 的 nativeDAGOwnerCancellation、nativePendingPairingRequestsV3/V4、nativeAccountReset、nativeAccountResetEmailRequest 仅是实际编译入口存在的投影。Dart 独立 verified 操作集合未改，默认仍空；realVaultReady 仍 false。PIN DAG 仍关闭，不允许 legacy fallback。

完整 Android arm64 AAR 固定 Go1.26.4、gomobile/gobind `v0.0.0-20260908204917-8b95e45f8d3e`、NDK28.2.13676358、BoringSSL `fab96f87245d7c6b941515201843665122650b88`，bind PASS 26.524 秒，AAR SHA256 `4033f8c018b1ceacaa9bccd7ab63fbb196b29a708062629d7064f56357adfcea`。真实 generated Java 包含 getter、pending、reset/mail 函数签名。全 native/MainActivity +真实 AAR/API36 Kotlin2.4编译最终 PASS 24.475 秒；七个非UI host程序合计60项 PASS 0.962秒（DAG9、pending15、七动作16、owner barrier5、原reset drain5、endpoint scope6、DAG admission队列4）。这是编译/host证据，不是 JNI、KeyStore、系统认证、网络或 Flutter 产品 PASS。

先前非空 B1/B2 SDK 的 b063 AAR 与四次真实认证证据保持独立；不能追认为本完整 AAR 或 B3/P2/P3 产品验收。下一步需要根审本联合 source/ABI/manifest 后再准备实际 Flutter P1/P2/P3 必要流程；本片无新安装、PIN、服务或 GUI 操作。
