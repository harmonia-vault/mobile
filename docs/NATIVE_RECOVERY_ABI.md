# 连续恢复与显式 cert4 原生业务合同

2026-10-03 UTC。这是非 UI 业务合同。固定公开core6eec463等加15有限候选的同一正常AAR/独立APK三阶段实际全部PASS94.475秒，30次系统CryptoObject提示含1取消、两次force-stop；实际可信恢复E及Android E批准正式CLI4通过。精确来源与历史失败见核心仓库 `mobilebridge/RECOVERY_NATIVE.md`；没有把当前工作树、新login/pending/PIN/UI算作产物。`realVaultReady=false`，默认gateway的产品用户链仍另行接线；界面只能按单操作profile及实验入口使用。旧 `recover`、`rotateRecovery`、`approveDevice`、`accountReset` 继续unsupported；本批没有新增管理者rotateRecovery API。

`NativeWorkflowAdapter(endpoint)` 只发送明确意图，每个下列业务调用均由原生重新执行真实系统强认证/CryptoObject、设备材料解包、Go protected-state 校验。全命令上限为 32768 UTF-8 字节，含元数据和 JSON 转义。Go owner、handle、私钥、bearer、原签包不跨 MethodChannel，不写 Dart 或磁盘。所有 ID 必须由同一意图复用；`PENDING` 不生成新 ID。

| Adapter 方法 | 参数 | 返回/下一步 |
| --- | --- | --- |
| `beginRecoveryAuthority` | 命名参数 email/password/recoveryCode（完整旧码） | Login + 开始受限恢复同一次认证；`data:RecoveryInfo`，并将旧 Ed owner 移交 Go 进程 registry。 |
| `resumeRecoveryAuthority` | 完整有效恢复码 | 仅进程死亡/期限或认证中断后重建原受限 context 的 owner；原 token/sessionHash/ID/nonce 不变。正常流程无需第三个旧码表单。 |
| `recoveryInfo` | 无 | 公开 `RecoveryInfo` 元数据，可在 owner 丢失时引导明确中断恢复。 |
| `recoveryView` | 无 | 必须有本次认证后精确绑定的活 owner；返回已验受限环境值，缺 owner 不返回数据。 |
| `beginRecoveryTransition` | 原稳定 id | 成功时顶层 `recoveryCode` 是本次完整新码，仅显示/完整重输、不持久化。 |
| `completeRecoveryTransition` | 完整新码 | 原 25 域两签包同步密封成功即退役旧 Ed；未知结果只能原包查询/retry。成功 full-vault + final-save 后新 owner 仅 RAM，仍 restricted。 |
| `queryRecoveryTransition` | 无 | 原 transition 元数据，不授予设备信任。 |
| `registerRecoveredDevice` | 原稳定 id、`List<NativeApprovalSelection>` | 明确选择环境/role/expiry，生成 cert4 双签及 HPKE，先原生密封；只有正式 Boot/Pull/proof3/final-save 成功 `trustedDevice=true`。 |
| `retryRecoveredDevice` | 原 id | 跨进程恢复原 cert4 journal；不能换 id、重签或依据 accepted 开 view。 |
| `recoveredDeviceInfo` | 无 | 原登记状态，无钥/原包；`accepted-not-applied` 必须原 ID retry。 |
| `approvePairingV4` | 命名参数 pairingId、Uint8List shortCode、explicit selections | 显式 cert4/proof3，仅目前 Go 支持的已登记恢复设备 E；120s 局部 PAKE 上限。短码独立字节参数，调用结束清可控缓冲，不持久化/发服务器。 |
| `retryApprovalV4` / `approvalInfoV4` / `cancelApprovalV4` | 原 pairingId / 无 / 原 pairingId | 沿原 journal；cancel 仅 prepared 且未尝试 HTTP，unknown 不可取消或改原意图。 |

`NativeApprovalSelection` 仅 `{environmentId,role,expiresAt}`；role 为 `ro/rw/admin`，expiresAt 为规范 Unix 秒字符串或 `"0"`，原生当前上限 16 个明确且不重复环境。不接受 Root/authority/proof/证书/封套输入。恢复轮换成功不自动登记、不自动 Admin；必须用户显式选择登记范围。

所有 adapter 返回 `{version:1,ok:boolean,experimental:true,data?,recoveryCode?,code?,retrySameId?,requiresRecoveryRestart?}`。平台认证异常使用 MethodChannel error：`AUTH_CANCELLED/AUTH_FAILED/AUTH_UNAVAILABLE/PROTECTED_KEYS_UNAVAILABLE/GO_OR_KEYSTORE_REJECTED/BUSY/LOCKED`；BUSY 不触发第二次认证，不取消正在进行的操作。Go 业务错误只给固定类别，没有内部 message/秘密。

`RecoveryInfo` 是 `{state,trustedDevice:false,rotationRequired,recoveryGeneration?,sequence?,environments?,id?,expiresAt?}`，typed state 为 `none/restricted/pending-new-code/accepted-unverified/rotation-complete-restricted/expired/expired-pending`。`RecoveryView` 是 `{info:RecoveryInfo,environments:[{id,keyVersion,variables:{name:value}}]}`，未认证目录名称不输出。`RecoveredDeviceInfo` 是 `{state:none|pending|expired-pending|accepted-not-applied|trusted,id?,sequence?,trustedDevice}`；任何 save 错误返回 false。

V4 `ApprovalResult` 是 `{state:approved|complete|unknown,pairingId,deviceId?,sequence?}`；`ApprovalInfo` 是 `{state:none|prepared|unknown|approved|complete|expired-pending,pairingId?,deviceId?,selections?,expiresAt?,sequence?}`。`approved` 与 sequence=0 不表示新设备 complete；仅已验新设备双签完成才 `complete`。

恢复固定业务错误：`RECOVERY_RESTART_REQUIRED`（`requiresRecoveryRestart=true`，明确中断输入有效完整码）、`RECOVERY_EXPIRED_PENDING`、`RECOVERY_RESTRICTED`、`RECOVERY_EVIDENCE_REQUIRED`、`PENDING`（原意图 retry）、`TRUST_INVALIDATED`（删本机 state/device/alias）、`UNAUTHORIZED`、`REJECTED`。旧码 owner 的取消、认证失败、保存失败、logout、失效、时钟回拨、expiry、dispose 都同步退役；普通每操作 `Workflow.Close` 只 detach。App 杀死丢失 RAM owner，AES journal 从不保存旧 Ed/Rx 私钥；已签原包可用完整新码继续原 transition。新 owner 同样短时且仅进程，不能作为一般登录或永久授权。

CRUD跨进程pending metadata/retry及loginAccount是下一独立合同；本份已测恢复归档的adapter没有这些新操作。完整源码/AAR/Android与清理已在恢复验收记录单列，不能将其他切片或当前HEAD作为该产物证据。
