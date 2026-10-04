# 已恢复 DAG 来源的 Dart 变量业务接线

本片基于公开 mobile `951e09d286bcb744e0c7471cfb4acc7823b13876` 的独立归档，只有非视觉业务源码与合成回归。没有修改 C 的界面、文案、布局或导航，没有构建新 AAR、没有操作 Android/服务，也没有扩大普通 writer 或恢复事务的操作名单。Go v1 交付只作为接口参考，存在已确认的终态错误丢因问题，不得用于 bind；新 AAR 必须等待 Go v2 最终审定。

## 固定入口与逐项门槛

`NativeDAGBusinessPort` 和 `NativeDAGBusinessAdapter` 独立调用 `org.harmoniavault/native/v1`：

- `dagBusinessProfile` 无参数，返回原生 String JSON；精确 version=1、profile=`issuer-recovery-dag-v1`、按字母排序的四项 operations。
- `executeDAGBusiness` 精确参数 `{command:String,value:Uint8List}`。command 只有 version=1、endpoint、operation 及下面的公开字段。没有 CA、私钥、平台 epoch、owner 指针、签包、token 或 caller trust bool。

| operation | 附加字符串字段 | value |
| --- | --- | --- |
| putDAGVariable | requestId、environmentId、name | 合法 UTF-8，允许空值 |
| deleteDAGVariable | requestId、environmentId、name | 空字节 |
| pendingDAGWrites | 无 | 空字节 |
| retryDAGWrite | 只有原 requestId | 空字节 |

command 上限 4096 UTF-8 bytes；ID 最长 64 ASCII bytes；变量名沿 128 ASCII 字符及大小写不敏感 `__HARMONIA_` 保留前缀限制；value 最多 65536 UTF-8 bytes、禁止 NUL。Dart 将值放在独立字节缓冲，不进入 command JSON；adapter、gateway 和 controller 的 finally 清理各自持有的调用缓冲。不宣称可硬清零 Dart String、Go/JNI 或运行时复制。

平台 `nativeDAGBusiness` 实际编译布尔、独立 profile 四操作名单、`verifiedDAGBusinessOperations` 逐项证据集合、当前 systemStrong 与原生保护模式共同控制能力。逐项证据默认空。存在 getter、广告编译能力、普通 profile 或 public key 都不开放写入。PIN、blocked、upgradeRequired 不进入本入口；没有认证降级。

## 来源与结果

普通 source 保留原路径；已恢复 DAG source 的 set/delete 只走专用业务入口。环境 CRUD、轮换、环境设备管理和 CLI 授权不能从可读 FullView 推导可用，也不会退回 ordinary Execute。

成功写删/重试必须得到精确 ok=true/trustedDevice=true envelope、applied=true 的单条 receipt，以及同次专用调用返回的成熟 `source` FullView。复用现有 DAG 来源投影解析，不在 Dart 重做密码学；再核账号/代际/device、原登记 ID/hash/acceptedSequence 与不倒退的检查点。controller 只在当前 scope/epoch 和真实前台恢复后应用该结果。成功结果已包含正式 Pull/final CAS 的视图，不能再用普通 Pull 替换它。

pending 成功与 ORIGINAL_RETRY_REQUIRED 都 trustedDevice=false、没有 view。pending 最多 32 项，immutable；每行只含 requestId、put/delete、environmentId、total=1、accepted、applied=false、canceled、sequences。成熟 Writer 实际源码将 sequences 固定为单项槽：accepted=0 时为 ["0"]，accepted=1 时为单条非零十进制安全整数；不兼容空数组。它们不能授信任。

新写前先读取本来源持久 pending。冷恢复具有相应逐项查询和重试能力时，controller 从正式恢复后读取原列表；未知原请求存在则保留现有 Locked 续办入口并阻断新写。两个原请求逐个处理，完成一个不隐藏另一个。取消认证不丢列表、不解锁。取消墓碑不可重试。

平台保存/网络异常只能留下本次 RAM 意图 ID 标记；它不声称已 seal/POST，不构成 durable journal 证明。须先从原生权威 pending 结果确认该 ID，再允许 retry。专用 retry 只传原 requestId、空 value，没有替代值、环境、名称、新 ID 或重新签名许可。原生硬失效保留固定异常类别并关闭会话；不靠 HTTP 正文把任意错误变成 soft 结果。RequiresDeviceDeletion 仍由原生成熟明确失效路径处理，Dart 不自称物理删除完成。

查询发现无待办也不能仅凭 metadata 恢复明文。现有显式解锁入口只有具备 `restoreDAGRecoveredDevice` 本来源逐项证据及 pending/retry 证据时才路由到正式 DAG restore，并再核原列表。后续正式 DAG Pull 也保留查询门。新账号/代际、原登记改变、检查点倒退、真正后台、取消、logout 或 scope/epoch 退役的晚到结果不应用。

## 本次证据边界

最终回归结果和源码 SHA 由独立 FINAL-MANIFEST 记录，历史语法/测试夹具失败日志保留。测试覆盖来源错路由、默认关闭、原 ID 冷续办、两个待办/认证取消、RO/失效、检查点/绑定、前后台晚到、严格 DTO 与独立值缓冲。这些是合成 Dart 业务/MethodChannel 证据，不是 Go HTTPS、JNI、CryptoObject、真实 Flutter 点击或 P1 产品完成证据。

后续顺序：Go v2 安全修复冻结并复审 → 同源码 AAR/真实 Java ABI与完整 Kotlin 编译 → 联合真实 Flutter 必要链 → 仅按实际证据逐操作开放。DAG 环境 CRUD、授权/撤销与期限管理仍由后续成熟高层实现；变量首片不完成 P1。

## 独立审查修正 v2

原 v1 冻结与 184 PASS 保留。独立审查发现：已核验原 ID 的 retry 遇平台未知异常会清 pendingKnown，但旧 verifiedIds/anchor 仍在，可能绕过下一次查询。v2 在 retry 入口同时要求 pendingKnown；retire 也将该门清为 false。新增已核验原 ID → retry 未知异常 → 未查询的下一 retry 零 native 调用 → 权威 query 后同 ID 可续办的回归。没有改变视觉、原生、软错误 DTO 或能力默认关闭条件。

同批第二修正：先前 peer 口头 accepted=0 空数组与真实 Writer/native conversion 源码不符。v2 采用单项 ["0"]，并拒空数组；旧 freeze 错误表述保留作为历史，不追改原日志。第三修正：明确 dispatched 标记，业务入口调用之后的未知/DTO 异常统一要求 suspendVault，保留明确失效类别及晚到 scope 隔离；调用前输入/能力拒绝不无故终止来源。新增 malformed 业务 response 与 cold restore pending response 的 controller 回归。
