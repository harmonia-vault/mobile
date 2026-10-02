# Flutter 与 Go 桥接边界

Go 窄移动桥、Android 系统强认证 AES 包封和真实 JNI 密码学已完成本机切片验证。Flutter 的可信设备入网、登录、共享同步和恢复尚未接上该切片，`FailClosedGateway` 仍拒绝真实操作且不进行网络请求。`SyntheticPreviewGateway` 是显式编译开关启用的内存示例，不用于真实保险库。

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

仍未接通：强生物实际成功/真机硬件保护、Android 首次可信手机与远程配对、真实共享同步/授权/恢复、iOS。`realVaultReady=false` 与默认安全动作拒绝保持。后续高层状态需用独立版本化 AES 文件和 AAD 绑定 endpoint、account/generation、双公钥与 checkpoint，不能复用当前固定 72 字节钥匙材料文件。
