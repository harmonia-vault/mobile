# Android App PIN 产品接线候选

本文件记录非视觉候选。`pinWorkflowReady=false`，Dart 独立 PIN 业务证据集合为空；尚不能声称产品已支持 PIN 登录、云端操作或 CLI 批准。原独立 5 项 Android JNI 测试只证明 core154 + f595 AAR 的本地组件，不能替代产品纵链。系统强认证的正常 AAR 7af 未替换。

## 固定通道

通道为 `org.harmoniavault/native/v1`。以下方法均严格外层 `version:1`，拒未知字段：

| 方法 | 额外参数 | 返回范围 |
|---|---|---|
| `localProtectionInfo` | `endpoint` | 下列十字段公开状态 |
| `setupLocalPIN` | `endpoint,pin,reentry` | 新设备公开 ID、Ed/X 公钥，`trusted:false` |
| `executePINWorkflow` | `command,pin` | 成熟 Go 业务信封 |
| `executePINApproval` | `command,pin,shortCode` | 成熟 Go PAKE/原审批包信封 |
| `executePINEnrollment` | `command,pin,shortCode` | 成熟 Go 入网信封 |
| `forgetLocalPIN` | `endpoint` | `version:1,cleared:true,trustedDevice:false` |

`pin/reentry/shortCode` 是当次字节缓冲。PIN 为 6–32 位 ASCII 数字，设置须完整双录，短码为 8 位数字；不将 PIN 放入意图 JSON、日志或长期 controller。`command` 沿用成熟 Go 完整意图，版本、endpoint、操作名、原 ID、环境、角色、期限均进入同一绑定。原生严格 Go 解码继续拒绝重复 JSON/未知操作/恢复旁路。现有 PIN Go 包装器不开放恢复入口。

十字段状态为 `version,profile,mode,systemCapability,deviceExists,pinSetupAvailable,upgradeRequired,pinWorkflowReady,delaySeconds,pinForgetAvailable`。profile 固定 `harmonia/local-protection/v1`；mode 为 none/system/pin/blocked，资格为 SYSTEM_READY/NO_SYSTEM_AUTH/BLOCKED；延迟为 0–600 秒。状态和清理资格均不授云端信任。

只有真实 classifier 确认 NO_SYSTEM_AUTH、无 system 保护残留且无旧 PIN 记录时，setupAvailable 才为 true。系统取消、认证失败、临时锁定、硬件暂不可用和未知资格不会转 PIN。每次业务重新检查实际资格、MAC、原 scope、整操作锁和 Go 租约。

## 清理与系统升级

`pinForgetAvailable` 只依据固定 PIN slot 的实际文件/alias 残留，并要求没有 system 保护残留。坏 MAC 可以返回 blocked 加该资格，便于登录/注册/blocked 页面明确本地清理；混合或 system 模式该值为 false。执行清理时在同一 PIN 整操作锁内再次核对 system 残留。

忘 PIN 只删除 PIN 所属的本机钥匙包、登录/缓存/原签包和该 slot alias，同步退役本机 owner；不删除云 vault，不解包或复用旧身份，不宣称云撤销。清理失败不报告成功；重新 setup 会生成新身份并须重新授权。系统后来提供强认证时，持久 upgradeRequired latch 阻止普通 PIN 业务；正确 PIN + 真 CryptoObject 的迁移尚未接线，不能自动迁移或回退。

## 生命周期与未知结果

PIN prepare 得到的 owner 通过 `PinOperationOwnerGate` 注册；注册和 disposed 退役共享锁。后台先发生时晚到 owner 同步 cancel 后拒绝执行；注册先发生时 dispose 取得并 cancel 它。该 gate 不创建认证资格或序列化许可。

LOCAL_PROTECTION_STATE、LOCAL_PROTECTION_PERSISTENCE、PIN_BLOCKED 等错误可能发生在 HTTP 已被服务器接受之后，不能归为确定无 POST。存在原 ID 时必须保持 unknown 和原 journal，并禁止新写；以原包状态/同 pull 收敛。只有明确的用户取消、Go 前能力拒绝或明确的错误 PIN 才是前置拒绝。approved 不等于新设备完成。

本地状态读取、MAC、解码或通道故障会关闭 Dart 明文视图、旧已验投影和业务能力，保留原未决 ID。已观察到 PIN 的上下文不能因 MissingPlugin/UNSUPPORTED 改走系统 provider；兼容只适用于从未有 PIN 的未实现平台。

## 已跑与未跑

- 原 8 文件 + f595 的完整 Android app 编译通过（35 秒）；产品 v1 dispatch/gateway 完整编译通过（22 秒）。后续根审查修复另有精确候选编译证据。
- Dart 业务/旧系统映射有限 35 项通过，包括晚持久故障原 ID 和状态故障后缓存关闭；这些是合成端口测试，不证明实际 HTTP、KDF 或系统资格。
- 原子 owner gate 的确定性 prepare/register 交错 JVM 测试通过；未执行操作、晚 owner 取消，已注册 owner 恰好一次退役。这不是 Android 生命周期或 JNI 实证。
- 产品真实 PIN → 空账号初始化 → CRUD → CLI3 PAKE 批准仍未跑。最终组合要以当前公开 coreb094 构建新 AAR，不能把 f595 的组件结果追认新树。

低熵 PIN 有离线猜测风险。Argon2id 和设备本地持久限流不能抵抗 root 级旧快照回放；软件钥保护不等于硬件内不可导出。可控缓冲会清理，但 Dart/Go GC、不可变 String 和 AES 内部 schedule 不能承诺全内存硬擦。
