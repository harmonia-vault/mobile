# Flutter 与 Go 桥接边界

Go 窄移动桥、Android 系统强认证 AES 包封、真实 JNI 密码学及独立首根管理手机高层已完成本机切片验证。Flutter 的可信设备入网、登录、共享同步和恢复尚未接上该切片，`FailClosedGateway` 仍拒绝真实操作且不进行网络请求。`SyntheticPreviewGateway` 是显式编译开关启用的内存示例，不用于真实保险库。

## 目标调用链

```text
Flutter 表单意图 → 原生平台保护/设备认证 → Go 核心
→ 在线签名密文提交 → 服务器接受
→ 相同持久序号拉取 → Go 验签、授权/检查点验证、解密
→ Flutter 只读视图更新
```

Dart 不实现密码学、密钥派生、SPAKE2、封套或服务器权限算法。界面不记录密码、短码或恢复码，且不在本地持久化这些输入；Dart 字符串不能承诺安全擦除。

## 后续原生适配要求

1. Android Go 绑定采用受维护的 Go 原生工具链；iOS 保留独立绑定目标。协商版本化 JSON 命令/结果协议，并严格验证输入大小、操作枚举和字段。
2. 账号密码仅在 Go 中按需求 SHA256；其结果是可重放的密码等价凭据，只能经 HTTPS 发送，不能用作保险库密钥。
3. 密钥需系统设备密码或强生物认证保护；缺少该能力时不生成可信设备、不解密真实秘密。软件保护不得声称始终硬件内。
4. SPAKE2 短码留在客户端配对通道，绑定账号、用途、会话与接收/签名公钥；界面角色与期限只能成为待批准意图。
5. 真实共享变更必须在线，服务器接受后才经验签序号拉取更新视图；收到撤销或本地授权到期立即清相关缓存。
6. 恢复受限会话与轮换查询结果由 Go 验证。绑定的一次 nonce、新码完整重输持钥证明、所有必要恢复封套原子切换全部通过后，才报告轮换完成。

当前 `PreviewMutation` 只用于合成内存演示，不是生产 wire 协议。真实桥将另行对齐 `protocol`，通过端到端安全测试后才替换拒绝执行的适配器。

## 已验证的 Android 原生切片（2026-10-02 UTC）

源码：核心仓库 `mobilebridge/`；手机仓库 `lib/native/native_business_adapter.dart`、`android/app/src/main/kotlin/.../nativebridge/`。Dart 只返回未可信双公钥和安全检查结果，不接收私钥。系统设备密码或 BIOMETRIC_STRONG 通过同一个 CryptoObject 认证后，Go 才生成/导入独立 Ed25519/X25519 软件钥；AES-GCM 包封文件位于 noBackup 私有目录，每次操作后关闭 Go Device。没有 Passkey、人脸要求、弱生物或明文回退；软件钥不宣称始终处于硬件内。

固定 Go1.26.4、gomobile/gobind `v0.0.0-20260908204917-8b95e45f8d3e`、Java17、NDK28.2.13676358 与固定 BoringSSL。x/mobile 工具依赖独立于主核心模块。`mise run go-native-build` 实际通过，生成 ignored `build/native/harmonia-go.aar`；`android-debug`/`preview` 依赖该任务，直接 Gradle 缺 AAR 会给出明确任务提示。NDK 需先按官方版本安装，不隐式下载或接受许可证。当前只支持 arm64-v8a，minSdk30，compileSdk36。

实际 Android14/API34 arm64 隔离 AVD 结果：原生业务 4/4（0.046 秒），系统设备密码包封/重新认证解包/不可复用旧认证/三次认证后双公钥一致 1/1（57.474 秒），取消认证精确拒绝且无设备文件 1/1（17.052 秒）。Go SHA256、Ed25519、HPKE、AEAD、固定原生 SPAKE2、篡改与未确认门槛均实际执行；不是只做交叉编译。未配置锁屏和配置合成 PIN 的门槛分别跑过。Go 普通与 native 标签 race 都通过。

原生验收使用 `-PharmoniaNativeFixture=true` 的独立合成包名，不读取旧签名钥、不覆盖原预览应用。临时 test alias/文件、AVD 合成 PIN、认证 dump 和两个新 fixture 包已清理；原预览包及其它 AVD 数据保留。APK/AAR、Go 工具与原始测试证据只在忽略目录，未发布。诊断日志已删除。

首轮之后的原生高层增量见下节。仍未接通完整 Flutter 流程、强生物实际成功/真机硬件保护、远程配对批准、恢复、角色/轮换和 iOS。`realVaultReady=false` 与默认安全动作拒绝保持。后续高层状态需用独立版本化 AES 文件和 AAD 绑定 endpoint、account/generation、双公钥与 checkpoint，不能复用当前固定 72 字节钥匙材料文件。

## 首根管理手机原生业务增量（2026-10-02 UTC）

新增核心 `mobilebridge/workflow.go`，Android `ProtectedWorkflowStore` 与 `executeWorkflow`，以及非 UI 的 `lib/native/native_workflow_adapter.dart`。独立 `workflowProfile` 明确逐操作能力，整个 `realVaultReady` 保持 false，默认 gateway/UI 不变。注册→合成邮件证明验证→一次登录与 Begin→完整恢复码重输双签初始化→持钥 boot/同验签 pull→环境和变量 CRUD 已在真实 AVD 原生入口运行。未实现批准/恢复继续拒绝，不能据此宣传生产可用。

系统强认证每操作解包设备钥后，Go 从高熵材料经标准 HKDF-SHA256 固定独立用途域派生本次软件 AES 状态保护钥；不是密码/SHA256登录凭据，也不改变独立云环境钥。原设备 72 字节格式不扩。独立版本状态包和 noBackup 文件绑定 app/slot/version、endpoint、账号/代际、精确双公钥和 checkpoint；Go 内层严格验证，AAD 标签失败/跨设备或端点即拒绝。状态包含已验证明文缓存与签名密文幂等日志，待初始化/撤销可含短时随机 token，只以密文交 JNI AtomicFile 保存，永不返回 Dart、日志或明文文件。本次完成后关闭和擦钥；不保证运行时所有副本或真机硬件内存擦除。

`SaveSealed` 同步完成权限、fd.sync、AtomicFile 提交和密文核对，失败阻止新共享 POST。提交后核对失败不保证恢复旧版，后续须从已认证持久状态恢复原事务或关闭；一次认证内允许多次软件 AES 保存，不复用 Keystore CryptoObject。unknown 继续查询/重试原 id 与原签包，不能自动生成新 id。dispose 取消当前 Go context/认证并拒绝后续保存；BUSY 阻止并发。退出/已知撤销清对应 alias、设备与状态文件；清理失败不假报完成，旧钥不会靠登录自动活。

实际结果：原生基础 4/4（0.043 秒）；高层完整业务与取消/BUSY 2/2（83.512 秒），包括服务器接受后丢响应→密封状态重建同 id 恢复、重复 id 检查点不增、变更意图冲突、保存失败无上传且旧密文保留、离线已验 view、环境/变量 CRUD、退出删钥/文件。真实 HTTPS 未信任测试 CA 拒注册 1/1（11.022 秒），未关闭链/hostname 验证。compileSdk36，实际运行 API34，二者不同。高层测试无需改 Flutter UI，只有隔离 AVD 的系统认证提示合成 PIN 交互。

构建与本机 HTTPS 夹具命令、NativeWorkflowIntegrationTest 公开 syntheticCA 参数和原生安全限制见 core-go `mobilebridge/README.md`。所有 APK/AAR/原始日志/公开临时 CA 仅在 ignored build；测试 CA 私钥只在进程内。最终结果见下段。

最终同一构建的全套 Android 原生 12/12 通过（184.013 秒，40 次设备密码系统提示含取消）。新增真实 Admin 自撤销：正常 200 返回已确认接受的 sequence 并清本机 alias/key/state；接受后合成 502 经密封事务重启，以原 id 先查询、再 boot 403 确认失效，返回 `completed=false / acceptanceUnknown=true / deviceInvalidated=true` 并清本机资料。pending 的 View/Pull/CRUD 拒绝，认证后的 `selfRevocationInfo` 只给原 id/expiry；120 秒到期清原 bearer 后只查询原 id，不重 POST 或隐式换 id，结果明确 `REVOCATION_EXPIRED_PENDING`。恢复码、签包、原 token 不返回 Dart。

最终Go普通/native race（1.446/1.393秒）、AAR/Kotlin main/test构建和分析（5.8秒）通过；AtomicFile中断/超限保持旧密文及0600实际通过。清合成PIN后未配置凭据基础4/4（0.028秒）仍failclosed。test alias/文件、两个nativefixture包及临时PIN均清理，原preview仍安装，AVD数据保留且无reset/wipe，HTTPS临时SQLite夹具已停止。原始日志仅ignored `build/native/workflow-full-runtime.txt`，未发布APK/AAR。Flutter UI/defaultgateway及整体 `realVaultReady=false` 未改；本段当时未接通远程批准；随后首根v2窄审批见下节。恢复、轮换、角色管理、iOS、真机强生物/硬件保护未算此历史证据。

## 首根原生批准 CLI（2026-10-02 UTC）

新增 NativeWorkflowAdapter.approvePairing/retryApproval/approvalInfo/cancelApproval，不接Flutter UI/defaultgateway，整体ready仍false。短码是独立Uint8List/ByteArray，仅本次系统强认证后进入Go BoringSSL；业务JSON只有pairingId与1–16个明确环境/角色/期限，不接受root/证书/封套。各op重新系统认证；只有approve局部120秒，其余30秒。来源只来自本机初始化原证据和当前已验授权，旧缺来源上下文failclosed。批准unknown不解除cache/write门槛，取消仅prepared未尝试HTTP；approved不表示新设备trusted。

同正常AAR focused原生跨端1/1，59.074秒；新mise复现入口又1/1，58.733秒，各21次系统提示含1取消/4 compiledCLI exit0。包含新手机真实firstroot/变量→MacCLI v2双签→boot/HPKE验签pull/own environment.sh导出与rw put；真实接受批准后502→原生新对象同id确认complete；prepared/attempted两保存失败都无批准POST，prepared可明确取消；auth取消/BUSY无state改动。短码只匿名pipe+局部ADB test socket内存，没有runner args、adb shell文本、HTTP、日志或磁盘传码。compileSdk36、runtimeAPI34。

Go普通/native race与正常AAR/Kotlin main/test构建通过；日志在ignored build/native/approval-*.txt。测试只本轮nativefixture包/Keystore槽、独立新CLI目录、合成.invalid账号与有限一小时rw范围；该通过基线及最新失败复测的PIN、两test包、文件/槽、CLI目录/进程和HTTPS夹具均已清；CLI目录/进程为0、forward无残留，127.0.0.1:4443连接被拒绝，原preview/API34 AVD数据保留且模拟器继续运行。cert3/非根/新环境来源、新Genesis恢复与恢复轮换仍待各Go合同最终冻结后单独原生验收，不靠本证据扩大ready。

可复现入口 `HARMONIA_TEST_SERIAL=emulator-5580 mise run test-native-approval`，需先按core-go/mobilebridge/APPROVAL_NATIVE.md准备fixed AAR/fixture APK、显式合法CA服务和隔离AVD测试PIN。上述通过对应当时默认v2的core-go c4dec971编译基线（working tree modified）；新版默认3后controller明确CLI `--certificate-version 2`，不自动降级。origin-aware复测55.248/54.702秒失败于第二候选verified Pull后，服务器补历史mutation授权及写入者归档双签身份闭包，未放宽客户端校验。新正常AAR+当前CLI(1801392+dirty，准确哈希见核心APPROVAL_NATIVE.md)仅一次freshfocused完整1/1 PASS59.634秒，21提示含1取消，四controller0；两候选双签/boot/verifiedPull/隔离导出/rw写、accepted502原id确认、两同步保存失败拒POST和Logout均实际运行。编译产物以记录哈希为界，后续Go源码改动不冒充已测试。成功只由真实JUnit与四compiledCLI阶段共同确认，失败清自身controller/forward；调用者仍须finally清PIN/fixture包/服务。详见核心源码仓库 mobilebridge/APPROVAL_NATIVE.md。

本轮fresh复测结束后的实际清理：noBackup测试文件为空、合成PIN清除、两nativefixture包卸载成功、新CLI目录/进程为0、测试forward无残留，HTTPS76196结束且127.0.0.1:4443连接被拒绝。原preview仍安装，API34 AVD继续运行且未reset/wipe。清理原始记录在ignored build/native/approval-fresh-cleanup.txt；未发布APK/AAR或自行提交。
