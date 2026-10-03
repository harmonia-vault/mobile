# Android C Flutter PIN 最小用户流程实测

2026-10-03，第六轮实际 Flutter 流程 **PASS，40.683s**：在真实 NO_SYSTEM_AUTH 的独立 API34 ARM64 模拟器中，使用 C Flutter 页面完整重输设置 PIN；错误 PIN 未发出变量写请求；正确 PIN 恰好接受一次写入并经相同验签拉取确认；正式 UI 忘记 PIN 清除本地材料；再次设置的新身份仍显示 NOT_TRUSTED。前五轮实际 FAIL 全部保留，未改为通过。

本轮是实际 Flutter 控件输入/点击 → MainActivity 原生插件 → Android Keystore/原子存储 → Go/JNI → 真实 HTTPS/SQLite。UI 产生本机设备后，合成账号注册、邮件证明、登录和保险库首次双签初始化使用同一受保护设备的成熟原生入口做 bootstrap；没有注入 trusted、设备私钥、缓存或来源账本。因此本轮不证明注册页面或恢复码向导的所有点击步骤。详细机器证据：[pin-flutter-runtime-20261003.json](../evidence/pin-flutter-runtime-20261003.json)。

## 输入与产物范围

实际 APK 的手机源码基线为 `8a0515c374dea6bd29e966e442c804b2222db7a7`，只加入经审阅的三个按范围开放的能力门控及一个显式空证据测试。发布基线为 `cc2286272e7d24ee54925f0d8f3db8e486d230e8`；这四个目标文件与实际构建基线逐字节相同，发布不会覆盖两者间的其它改动。

实际 Go 基线为 `c8b66ac7cc6ee8d10abc834d90ecc4d80be6d774` 加精确 PIN preflight 错误分类修补。仅当成熟 `Provider.Unlock` 返回直接相等的 `appsecurity.ErrPIN`，其 Release 和退役已成功、包装器最终同步退役也成功，并且尚未 Import/OpenWorkflow 时，才返回固定 `PIN_AUTH_FAILED` 失败 JSON。持久化、Release、关闭或退役失败仍覆盖为错误；没有从异常文案判断，也没有吞掉组合故障。错误 PIN 保留 durable precharge 的失败计数和 PendingAttempt。私有 ABI 签名未变。

服务使用独立合成空实例，固定公开基线 `bd86fec6215b6f7149234578e7bf5dc764a639c2`；SMTP 不发真实邮件，测试邮件在实例 RAM 中捕获。没有使用真实账号、环境变量或凭据。

| 产物 | SHA256 |
| --- | --- |
| 本轮候选 AAR | `f943c4c207a79ce5e0fc2091a7b58aa13f83e7421012d3176041c85a6ef3e5fc` |
| Debug 主 APK | `aaa5be2edb2c651f32d4d777dda03bb9924caeb4d0a54db50241250b4080871d` |
| 过滤 Instrumentation APK | `e57bbebd60b892a4b72980306072c00128e765df4daac7d5b75ede0b48eb3c64` |
| 本轮固定公开字段原始输出 | `c7f9818e5172e780b90151d6a7fdd56603bd5f62fe98ea789395bf929a8e71fd` |
| 27 项实际输入 manifest | `ec4f58f84868ca751426516730b5deffe2a2c39fd0759a048c3e6bdaef5d4abf` |

固定 Go1.26.4、既有固定 gomobile/NDK28.2.13676358/BoringSSL，候选 AAR 单次构建 PASS 5.326s；APK 组合构建 PASS 11.874s。定向真实 Argon2/AEAD race 8 主、6 子 PASS，package 16.129s，进程 23.511s；vet PASS 3.569s。四个手机候选的 analyze PASS 5.027s，现有 Dart 90 项测试 PASS 8.125s。正常共享 AAR、宿主环境和其它测试账号没有替换；开发构建须重新从匹配的 Go 源码生成 JNI，旧 AAR 不能代表新包装器。

## 逐阶段结果与门控

| 实际阶段 | 结果 |
| --- | --- |
| 资格 | 第一次读取为 none / NO_SYSTEM_AUTH / 无设备 / 无 PIN 清理残留；没有伪造 classifier、改变系统 PIN 或时钟 |
| C Flutter 设置 PIN | 两个真实编辑框完整输入并重输，原生持久提交成功 |
| 同设备真实 bootstrap | 成熟账号与邮箱证明、登录、完整恢复码重输、双签首次初始化和验签 Pull 成功 |
| 打开已授权保险库 | restoreSession、pending 元数据和 Pull 分别使用新的 PIN 输入与一次性 lease；实际显示已验证环境 |
| 错误 PIN 变量保存 | 正式认证失败提示；mutationAttempts=0、mutationAccepted=0 |
| 正确 PIN 变量保存 | mutationAttempts=1、mutationAccepted=1；随后独立 PIN 确认 Pull，已验证值正确 |
| 正式 UI 忘记 PIN | 清除该 PIN 所属登录、钥匙与缓存；原生读回 mode=none、无设备/清理残留；云端已接受变量仍为一次 |
| 再次设置 | 新本机身份没有云端可信授权，仍显示 NOT_TRUSTED |

原生插件逐操作验收的 16 项来自独立 [MainActivity PIN 纵链证据](PIN_PRODUCT_RUNTIME.md)：register、verifyEmail、loginAccount、beginInitialization、completeInitialization、restoreSession、businessPendingInfo、retryBusinessOperation、createEnvironment、renameEnvironment、deleteEnvironment、setVariable、deleteVariable、approvePairingV3、retryApprovalV3、pull。其中包含真实 CLI3 配对批准、可信 daemon Boot/RW 以及原 ID unknown 重试。该证据与本轮 Flutter 输入证据分别保留；本轮没有再次运行 CLI 或声称点击了全部 16 项 UI。

能力列表逐操作开放，并且每次仍要求 native 实际 MAC 状态有效、hasPIN、无系统材料、无 upgrade latch、NO_SYSTEM_AUTH。none、blocked、混合残留、系统认证取消或临时失败不走 PIN。ABI 的 ready 不表示设备可信；实验开关仍显式，realVaultReady 仍为 false。PIN 恢复/RAM recovery owner、系统升级迁移、V4/V5 批准与多次恢复、iOS 完整 PIN 产品链不在此证据中，继续关闭。安全功能不能据此宣传生产可用。

## 保留的实际失败

| 轮次 | 整体结果 | 原始边界/后续处理 |
| --- | --- | --- |
| 1 | FAIL 14.046s | setup 后 native 读取拒绝；当时未记录精确拒绝 code。后续观测 BUSY，驱动增加正式完成等待与只读 BUSY 有界重试 |
| 2 | FAIL 9.639s | 真实本测试 PIN 残留使严格 fresh-slot 门槛拒绝；未绕过资格，后续仅经正式清理入口处理自己的合成残留 |
| 3 | FAIL 38.247s | setup 和真实初始化通过；驱动漏了 pending 元数据/Pull 所需的独立 PIN 提示，按正式操作顺序补齐 |
| 4 | FAIL 24.259s | 驱动误用 Flutter 导航中的旧 PIN 对话框节点；改为旧可编辑节点实际退役和新唯一可编辑节点/确认按钮就绪 |
| 5 | FAIL 44.852s | 已显示真实可信环境；错误 PIN 的真实 Go/JNI 错误被归为 PIN_BLOCKED，导致保守关闭。用精确 preflight sentinel 修复，未放宽 UI 断言 |
| 6 | PASS 40.683s | 本文完整最小流程，六个必要阶段全部通过 |

驱动对 PIN 对话框逐次确认真实编辑节点身份，不用固定 sleep 假定新授权。所有日志只含固定类别、数字、哈希和布尔；没有 PIN、恢复码、设备私钥、token、变量值或整树输出。末次读 metadata 的 BUSY 仅有界重试只读方法，没有重放 setup 或共享写入。

每轮只使用本人隔离 5582，保持 5580、既有 ADB server/钥匙和旧模拟器不变。本轮正式 PIN final cleanup 成功；只卸载本次两个包，原 171 个 stock 包 baseline 相同；本人模拟器进程 exit0，保留其磁盘目录；4453 合成服务已停止。
