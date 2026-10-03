# 账号登录、可信会话投影与原业务事务续办合同

2026-10-03 UTC，非 UI 独立切片。与连续恢复14操作合同分开。四个helper/profile/业务adapter已接通；固定公开core5040921/mobile56ac910+7明确候选的同一正常AAR实际Android三阶段3/3 PASS62.370秒、22次CryptoObject、两次真实force-stop。标准HTTPS登录/错误密码/未知CA/未授trust及严格原ID测试、常规/native bridge与registry race已通过，adapter analyze通过。精确来源、产物与历史失败见[核心ACCOUNT_NATIVE.md](../../core-go/mobilebridge/ACCOUNT_NATIVE.md)。整体ready仍false，Flutter产品用户链未计入本证据。

所有意图走 `NativeWorkflowAdapter(endpoint)`、原生 `executeWorkflow`，命令为 `{version:1,operation,endpoint,...字符串字段}`；每次新的系统强认证/CryptoObject与受保护状态核验。整段命令最多32768 UTF-8字节。不接受 token、公私钥、whole state、authority、签包或变量替代字段。整体 `realVaultReady=false` 不变。

| Adapter 方法 / operation | 唯一字段 | 成功 data |
| --- | --- | --- |
| `loginAccount(email,password)` | email、password | `{authenticated:true,trustedDevice:false}`。只有成熟 Go 标准 HTTPS 登录真实成功才返回；随机 session 只在当次 RAM，Workflow.Close 清除。 |
| `restoreSession()` | 无 | `{trustedDevice:true,accountId,accountGeneration,deviceId,view}`，仅成熟Go已验View/有效权限/同步最后保存全成功且当前inner account/gen/device/checkpoint精确匹配才返回。仅登录、未可信、受限或尚未Applied的设备入网/恢复不返回该DTO。 |
| `businessPendingInfo()` | 无 | 原密封事务有限元数据数组，最多32条变量写及32条环境交易。 |
| `retryBusinessOperation(id)` | 原稳定 id | 原事务单条元数据，不重签、不换 id、不接受新值。 |

元数据固定 `{id,operation,environmentId,state,sequence,applied}`；state 为 `unknown/accepted-not-applied/applied/canceled`。`applied=true` 只表示同一验签下发与最后原生保存全部成功且该调用无 error。取消墓碑不可重新提交；ID碰撞或不存在拒绝，不生成新ID。List不联网，不返回变量名、值、密文、签包或 session；Retry仍通过成熟Go原包查询/提交与当前权限检查。

统一结果 `{version:1,ok,experimental:true,data?,code?,retrySameId?}`。登录失败不返回认证成功元数据；普通业务类别沿既有 `REJECTED/NOT_TRUSTED/PENDING/ID_CONFLICT/UNAUTHORIZED/TRUST_INVALIDATED`，平台认证沿 `AUTH_CANCELLED/AUTH_FAILED/AUTH_UNAVAILABLE/PROTECTED_KEYS_UNAVAILABLE/GO_OR_KEYSTORE_REJECTED/BUSY/LOCKED`。未知结果只能保留原ID续办。

登录成功只导航账号向导，绝不证明服务器已授权本机或允许 View/Pull。初始化/入网/恢复下一操作仍分别 JITLogin；Dart不持久密码/随机session。现保护record已有可信root、pending、closed或受限恢复时，保留成熟Go拒替换门槛。App重启后没有可从Dart复活的登录；已有真实可信设备只能新的OSauth之后用verified View/Pull恢复，未可信设备须重新真实登录。UI本地bool不得进入保险库。

restoreSession不联网，其view来自已经验签并绑定来源的本地受保护cache；新的pull仍独立认证并联网检查当前状态。Dart不能用公开设备公钥、publicendpoint配置或文件header复活账号范围。公开endpoint留存/真实instance-info/切换scope另作连接slice，不属于这四个操作。

环境结果不明可返回REJECTED+retrySameId=true；这不证明未接受，必须保留原ID与unknown/appliedfalse元数据，不换ID。restoreSession没有审批来源版本字段，冷恢复后审批保持关闭，不能据pubkey/root猜版本或试错fallback。
