# Android DAG 业务接入与 P1/P2/P3 联合候选

日期：2026-10-04 UTC。此文件是独立候选方案，不是产品验收报告。

后续同来源 normal AAR、实际 Java ABI 与 API36 全原生编译已通过；见[编译记录](ANDROID_DAG_VARIABLE_COMPILE_20261004.md)。下文保留接线时的候选设计与当时进度，后续结果以上述记录为准。JNI、系统认证与真实 Flutter 产品流程仍未验收，能力默认关闭。

## 固定来源与分工

本候选从公开 mobile `951e09d286bcb744e0c7471cfb4acc7823b13876`、core-go `28a35f286e9ff4bafabf62c0daedca84e0530de3` 导出，完整来源哈希见候选 `PUBLIC-BASE.json`。之前原生联合候选 v3 的 60 项 host、API36 编译与 AAR `4033f8c018b1ceacaa9bccd7ab63fbb196b29a708062629d7064f56357adfcea` 保持历史范围；它尚不包含本片新增 Go 业务 ABI。本片不重认旧 AAR 为新业务通过。

core_cli 独立负责 mobileworkflow/mobilebridge 的 DAG 变量业务、严格 DTO、原包日志和真实 HTTPS 验证；mobile_bridge 负责本片 Android 私有通道、认证、provider、生命周期、跨 dispatcher 排空。Flutter 业务由 core_cli 协调，界面仍由指定 Claude 负责。本候选不修改 Flutter 或旧冻结目录。

## 已确认的产品缺口

`mobileworkflow/recovered_dag_device.go` 从已确认的原登记 journal 建立 P4 verifier，核 account/generation/device 双公钥、原接受序号、完整 issuer DAG、授权下界和本机 whole-state CAS。B3b 的 apply/restore/pull 可返回可信完整视图。

普通 `checkWithoutManagement` 对 DAG state 明确拒绝；普通 SetVariable/DeleteVariable/PendingBusinessOperations 和 ManagementDevices/PrepareDeviceGrant 不能作为恢复设备的退路。`validateRecoveredDAGDeviceLocked` 当前还禁止普通 WriteJournal、EnvironmentWrites、Management 与 DAG 记录混用。新增业务须保存独立、精确绑定的 DAG journal，并由 Go 扩展成熟来源验证；Android 不篡改受保护 JSON。

环境高层 `environmentOriginJournal` 当前只有 P2 Control/P3 RecoveryControl，submitEnvironmentOrigin 选择 V2/V3 路由，managementRecordClient 仍用 originVerifier。底层已有 DAG control、EnvironmentStatusV4/SubmitEnvironmentChangeV4/ConfirmEnvironmentChangeV4，并不足以证明手机高层已接通。环境与授权管理仍是 P1 完整产品的必需后续，不能因变量首片通过而勾选 P1。

## 双方确认的变量首片合同

独立 MethodChannel `executeDAGBusiness` 只接 `{command: String, value: Uint8List}`。不增加普通 workflowProfile 或 DAG Recovery 的 20 项白名单。

command 是 Go 严格平面 JSON：version=1、endpoint、operation，加下表唯一字段。value 独立字节，不放 JSON、日志或受保护头。双方定型 Kotlin/Go command 上限 4096 UTF-8 字节、value 65536 字节且无 NUL；requestId/environmentId 用现 ASCII ID 模式，name 最多128字符且拒绝保留前缀大小写变体（由 Go 检查）。Kotlin 拒绝坏 UTF-8 并清解码临时缓冲；所有入口均消费调用方字节副本，失败与排空 finally 清原生缓冲。Dart String/Go GC 不宣称可硬清零。

| operation | 额外 command 字段 | value |
| --- | --- | --- |
| putDAGVariable | requestId、environmentId、name | 严格 UTF-8，允许空值 |
| deleteDAGVariable | requestId、environmentId、name | 必须空 |
| pendingDAGWrites | 无 | 必须空 |
| retryDAGWrite | 仅 requestId | 必须空 |

独立零参数 `dagBusinessProfile` 只返回 Go 固定 `{version:1,profile:'issuer-recovery-dag-v1',operations:[排序的四项]}`。getter 与编译 capability 不授 trust；Flutter 默认 verified 集合仍为空。新增 Get/Validate/Execute 的实际 Java ABI 须待 Go 冻结后重新绑定并核 javap，不伪造接口或复用旧 AAR 猜方法。

Go 成功 put/delete/retry 的交付要求：原来源与现权限验证、原签包前置 whole-state CAS、真实提交/原状态确认、正式 P4 verified Pull、最后 whole-state CAS 和 postCheck 全部成功。只使用 Go 返回的有限 write 元数据与成熟 DAG fullView；Kotlin 不拼 trustedDevice=true。pending outer trustedDevice=false，data 精确为 `{pending:[{requestId,operation:put|delete,environmentId,total:1,accepted:0|1,applied:false,canceled:bool,sequences:[十进制字符串]}],trustedDevice:false}`，无变量名/值/密文/签包且不返回 trustedView。

未知回应保持原 requestId/原签包；固定 ORIGINAL_RETRY_REQUIRED 与 applied=false 只能恢复原请求。冷进程经新认证、新 provider 验原本机 journal，retry 命令没有新 env/name/value 可替换。陌生 ID、换账号代际、来源损坏、失权或 CAS 不匹配必须由成熟 Go 拒绝，不能凭任意 HTTP 文本保留信任。RequiresDeviceDeletion 继续走现 native 精确删除合同，不新增裸状态、裸签名或删除布尔入口。

## Android 最小实现边界

新增 `NativeDAGBusinessChannelRequest.kt` 管理精确 envelope/缓冲；新增 `NativeDAGBusinessDispatcher.kt` 已在私有候选落盘，沿现 NativePendingPairingsDispatcher 的系统认证和强保护路径，绑定每次 fresh NativeSlotOwner、真正 CryptoObject、ProtectedWorkflowStore、OpenAtomicWorkflow。normal business 不持有恢复 Ed owner，不复用上次 workflow/provider/cipher/permit。

NativeBridgePlugin 只增加两个固定方法和新 dispatcher 的互斥/生命周期转发：DAGRecovery、普通/PIN、pending、mail、reset 与 DAG business 双向 busy；busy 包括 worker/main 已排空前的 drain。P3 authoritative query 后的 all-owner barrier 必须先排空 DAG business；普通正式 logout、PIN forget/switch、dispose 亦不遗漏它。取消/后台立即 invalidate 自己在途 ctx，最终完成仍受真实 resumed、原 permit deadline、当前 scope 和完成一次约束。Close/slot release 不明粘性闭锁，不能新操作复活。

先 Go Validate 与固定 fixture endpoint 拒绝，再系统认证；成功 OpenAtomicWorkflow 才给当前 native RAM endpoint scope 投影。background 不换 endpoint。恢复流程仍走 executeDAGRecovery 与稳定 platform epoch；普通 DAG business 不借 Dart foreground/可信 bool/公钥推断来源。

## 联合候选与实际产品步骤

最终产物须联合固定公开 native base、core_cli 的 DAG business freeze、route12 业务接线和 Claude presentation 候选各自 manifest。未收到的确切路径/hash 继续标待核，不自行选视觉或合入 live。AAR 只在有限最终 Go 合集冻结后构建一次；记录编译源 map、真实 ABI、Kotlin/APK/fixture CA/config 哈希。不得沿旧 SDK 非空 B1/B2 证明 B3、变量或 Flutter。

| 产品流程 | 最小实际调用 | 当前依赖/阻塞 |
| --- | --- | --- |
| P1 受限恢复 | 创建钥匙；openDAGRecoveryOwner；begin/seal/retry 原 transition；显式 choices/seal/retry 原本机登记；apply→正式 Boot/P4Pull/finalCAS | Recovery/B3 Go 已有独立来源；新联合 Kotlin/Flutter 实际链尚未跑。完整码仅当次内存回填，每次独立系统认证 |
| P1 日常变量 | 已应用 DAG scope；put/delete；读取正式返回 view | 本片 Go/Android 新 ABI 与 Flutter 映射待冻结和实际验收 |
| P1 原请求恢复 | 合成单笔接受后丢回应；force-stop；强认证→pending→同 requestId retry；正式 Pull 后显示 | 只查询/重试原签包，无新 ID/新 value；不重复基础矩阵 |
| P1 环境/授权管理 | DAG 环境 create/rename/delete/rotate；每环境设备/grant/revoke 原包续办 | 手机高层 DAG journal/P4 source 适配仍缺，单列必需，未开放 |
| P2 前台配对提示 | executePendingPairings 精确版本 GET→纯元数据；后续明确审批 | native 编译已有，不等于 Flutter badge/实际批准验收。恢复 DAG 能否批准新设备另需成熟 profile，不能落到旧 V3/V4 |
| P3 账号重置 | requestAccountResetEmail→begin/queryOnly→query→prepare→complete；cancel 仅本地退休 | 七动作已编译，邮件申请非敏感路径不假称可信；真正原槽匹配/强认证/全 owner 排空和新 Flutter 全路径仍待实测 |

运行顺序由 root 分配服务/AVD lease。当前仅宿主 envelope/编译工作，无服务/ADB/install/PIN/截图/GUI。下一实际申请应是联合源码的必要 P1 产品流程，不再扩空 metadata/诊断矩阵；P2/P3 用各自必要产品路径，结果逐项记录且保留旧失败。每轮 finally 核本人临时包/forward/系统合成凭据/Node/SQLite 清理，未知保留真实 UNKNOWN。

## 本轮实际范围

仅 envelope 组件完成 Kotlin host 验证。新 dispatcher/Plugin 候选已保存，完整新 Go ABI/AAR/Kotlin 集合验证须等 core_cli 最后 HTTPS 与源码冻结；当前全部 Android/JNI/Flutter 产品执行均 UNRUN。当前编译声明源不等于已验 capability，默认 verified 集合不动。

关闭不明的 `cleanup.unconfirmed` 只使 admission 永久闭锁。dispose 依据内部 operation/drain 是否仍活跃决定 executor shutdown，不能因 sticky busy 在没有 worker 时留下线程；有活跃操作仍由既有 worker finally 完成后 shutdown。此窄修保存为候选 `STICKY-EXIT.diff`，不是 Android 实测结果。
