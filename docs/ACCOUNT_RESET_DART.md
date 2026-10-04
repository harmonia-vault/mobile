# P3 账号重置非视觉合同

本文保留最初独立业务切片的合同和当时验证范围。后续 Go 邮件入口、七动作 MethodChannel 端口及新增验证见 [七动作重置端口](ACCOUNT_RESET_CHANNEL.md)；下文“当前未实现”描述仅指本初始切片，不代表后续端口仍缺失。平台实际 SDK 清理与完整产品验收仍未完成，默认验收能力保持关闭。

这是实验性业务接线，不是产品验收。界面通过独立 `AccountResetActions` 消费状态，不改现有恢复向导、普通工作流或默认能力。当前没有已批准的 P3 MethodChannel 名称、编译 getter/cap 或申请重置邮件原生入口；`NativeAccountResetAdapter` 默认编译名单与验收证据均为空，因此全部关闭。

## UI 入口

`AccountResetCoordinator(gateway, scope, changed: ..., retireVisibleAccount: ...)` 实现 `AccountResetActions`。`scope` 是固定 HTTPS 地址及可选、此前已核验的当前账号/代际，不能从新 proof 声明替换已有 tuple。`changed` 只通知状态；`retireVisibleAccount` 在 Complete 前撤回旧保险库展示和 UI 会话，失败则不调用完成入口。该回调不能批准 Go 删除、提供 cleanup 布尔或证明本机已清理；原生仍独立核验 AEAD 来源和物理槽。

| 方法 | 输入 | 业务边界 |
| --- | --- | --- |
| `requestAccountResetEmail(email)` | 本次邮箱 | 只有申请邮件成功才能进入新流程；当前 native adapter 明确不可用，不走 Dart HTTP。 |
| `beginFreshAccountReset(emailProof)` | 完整邮件证明 UTF8 字节 | 仅明确新申请流程；原生 begin 先 Query，不能充当冷重启恢复。 |
| `queryColdAccountReset(originalEmailProof)` | 原邮件证明 UTF8 字节 | 创建永久 queryOnly owner；没有 Prepare/Complete 能力。 |
| `queryOriginalAccountReset()` | 无 | 只查询当前同 RAM proof / Attempt；不替换地址、证明或密码。 |
| `prepareAccountReset(newPassword, destructiveConfirmation: ...)` | 一次新密码 UTF8 字节及完整确认文字 | 先成功 Query pending；确认必须为用户明确输入的 `DELETE_OLD_VAULT`；只有一次 Prepare。 |
| `completeAccountReset()` | 无 | 原生再次 Query，并完成本机匹配 Logout、真实删除、重新空槽核验与最终 drain；只沿原 Attempt。 |
| `cancelAccountResetLocally()` | 无 | 立即退役本机 RAM/epoch 并请求原生取消；不等 busy 锁，不表示服务器关闭或物理清理完成。 |

邮箱证明是邮件提供的完整四字段 JSON `{accountId, accountGeneration, challengeId, token}` 的 UTF8 字节，不是单个 token。Dart 不拆解或拼造该 JSON；Go 对精确字段、代际和 32 字节无 padding base64url token 进行成熟核验。证明上限 4096 字节，密码上限 16384 字节。传入可控缓冲在成功、失败或未发送时均被消费并清零。Dart 字符串不能保证彻底擦除，UI 不得持久化、打印、截图保存或自动填入输入。

`accountResetFormScope` 是本机表单生命周期标识，`retainAccountResetInput` 在后台、忙碌及退役时为 false。UI 应按同一 scope 保留交互中的输入，并在 scope 改变、后台、取消和销毁时立即清空文本控制器和自己持有的字节。取消与后台分别调用 coordinator 的本机退休入口；退出账号或端点变化调用 `invalidateScope()`，销毁调用 `dispose()`。退役后的 coordinator 不重新开启新流程，晚到成功或错误不能改变新状态。

## 公开状态

`AccountResetPresentation` 只包含 stage、固定中文 status/error、busy、公开 accountId/accountGeneration/source、queryOnly、localCleanupConfirmed 和动作集合。`trustedDevice` 永远 false。没有 proof、密码、token、签包、hash 凭据或原生句柄。

| stage | 含义 |
| --- | --- |
| `unavailable` | 没有同时满足编译声明和验收证据的原生能力。 |
| `entry` | 可明确新申请或冷查询；新申请未成功不得创建原 payload。 |
| `awaitingProof` | 本次申请已成功，等待完整新邮件证明。 |
| `proofPending` | 原 Query 返回 pending；queryOnly 时仍禁止新请求。 |
| `prepared` | 原 RAM payload 已确认冻结，不能替换输入。 |
| `unknown` | 结果未知；只能先查同 RAM 原请求。 |
| `serverComplete` | Query 已确认服务器重置，仅此不能报告本机清理成功。 |
| `complete` | 成熟原生 Complete 最终成功交付，本机清理已确认；仍不登录或授信任。 |
| `interrupted` | RAM 已退役或清理不明；冷续办只能查原证明。 |

已知账号不匹配或代际不是 pending 原代际 / complete 精确原代际+1 时硬拒绝。complete 不能倒退成 pending。完成不恢复旧 vault、不自动初始化新 vault、不授新设备权限。UI 应离开旧保险库展示，后续登录/初始化/可信入网走原正式流程。

## 未知结果与冷重启

同 RAM Complete 未知后，直接再次 Complete 被阻断；先 Query，再以无替代参数的原 Complete 续办。Query complete 也只标服务器完成；仍有原 Attempt 时可经 Complete 做成熟本机清理，Go 不再 POST 已完成请求。

Prepare 回应未知时不猜其是否已成功冻结，禁止第二次 Prepare 和未确认的 Complete，只能查或退役。进程丢失后不持久保存 payload 或密码等价字节；必须用 `beginQueryOnly` 读取原证明状态，不能用新密码自动重签重交。申请邮件的 accepted-only 回执不是任意旧 proof 的新申请证明。重新开始必须明确重新申请邮件，不以冷查询改名为新流程。

## 原生 port 和严格结果

`NativeAccountResetPort` 只有六个对应已审内部 delegate 的 typed 方法：`begin(endpoint, proof)`、`beginQueryOnly(endpoint, proof)`、`query()`、`prepare(password, confirmation)`、`complete()`、`invalidate()`。它们是待平台接线的 port，未指定不存在的 MethodChannel 名字。平台必须保留 P3 原生 owner/认证/清理/drain 合同；不得在 Dart 实现 Go cleanup adapter。申请邮件仍是明确未接通的独立缺口。

Query / begin 成功 JSON 恰好为：

```json
{"version":1,"trustedDevice":false,"outcome":{"state":"pending","accountId":"synthetic-account","accountGeneration":"1","source":"status"}}
```

查询 complete 使用精确新代际并仍为 source status。Complete 可返回该 status complete，或 exact commit 结果：

```json
{"version":1,"trustedDevice":false,"outcome":{"state":"complete","accountId":"synthetic-account","accountGeneration":"2","source":"commit","replayed":false}}
```

Prepare 成功恰好为：

```json
{"version":1,"prepared":true,"trustedDevice":false}
```

结果上限 4096 UTF8 字节，拒重复键（含转义同名键）、额外字段、数组、错版本/类型、错误来源与设备信任。原生异常只投影固定类别，不能回显平台错误原文、proof 或密码。Complete 结果只有成熟最终回调可交付；Dart 不接受 caller 的“已经清理”布尔。

## 实际验证边界

固定 Flutter 3.47.6 / Dart 3.13.5，只运行新增单文件的八项合成业务测试及定向静态分析。测试覆盖默认门零调用、严格 DTO、一次 Prepare/缓冲清零、Query-before-Prepare、同 RAM 未知原请求、冷 queryOnly、账号/代际门、后台/状态通知取消及晚到结果。UI 缓存退休 callback 不代替原生实际删槽测试。

本片没有运行邮件、HTTP、MethodChannel、Android/iOS、系统认证、SDK、VM 或 UI；P3 产品验收未完成，capability 没有开放。原 analyzer lint 失败及格式脚本测试夹具错误日志保留；最终同八项测试和 analyzer 均通过。
