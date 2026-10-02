# 手机端验证记录

记录日期：2026-10-02（UTC）。目前为合成预览和原生业务桥接开发阶段，不代表生产安全验收。

## 已实际通过

- 固定 Flutter 3.47.6 / Dart 3.13.5、Temurin Java 17.0.16+8；Flutter 静态分析通过，9/9 控制层测试通过，无 UI 单元测试。
- 官方 Android NDK r28c 28.2.13676358 完整下载，SHA1 实测 `fc20a6bf15a30fb3428c9b60a7308793a362dc6d` 与官方一致；使用 Android SDK 19.0 管理目录。
- `mise run android-debug` 实际构建 APK；第一轮 Maven 下载 TLS 握手短暂失败，Flutter 自动重试后退出 0。
- 隔离 API34 ARM64 AVD 实际 `sys.boot_completed=1`；ADB 安装返回 Success，启动实际应用成功。
- 从实际 Android 应用抓取并人工检查七张截图：环境列表、环境详情、设备列表、设备审批、恢复、恢复码轮换、设置。截图已交付用户，使用 `.invalid` 合成账号和脱敏变量；APK、AVD 和截图不作为源码二进制发布。
- 固定 BoringSSL Edwards25519 SPAKE2 draft02 源码的 Android ARM64 编译与 Go ELF 链接通过。Go 原生桥 gomobile AAR 已生成；实际运行结果见下方。

## 范围与未跑

默认 `FailClosedGateway` 拒绝真实网络与安全动作；`HARMONIA_PREVIEW=true` 仅启用合成内存 CRUD。界面截图不证明登录、可信设备审批、恢复或系统钥匙保护已接通。认证只采用系统设备密码或强生物认证，不使用 Passkey，也不声称软件钥始终位于硬件内。

iOS 保留工程兼容骨架，未构建或运行；Android 模拟器的强认证成功、取消、过期及设备密码变更结果必须由原生测试单独给出。测试不使用用户真实账号、凭据或宿主环境变量。

## M2 原生桥终轮（2026-10-02 UTC）

- Go 普通/native 标签 race 均通过；固定 AAR、`mise run go-native-build`、Flutter analyze 与含原生依赖的 `mise run android-debug` 终轮均通过。
- 实际 Android14/API34 ARM64（compileSdk36、minSdk30）原生业务 4/4 通过，0.046 秒：SHA256、独立 Ed/X、HPKE、AEAD、固定原生 SPAKE2、篡改与未确认拒绝。
- 系统设备密码生命周期 1/1 通过，57.474 秒：三次独立认证完成生成包封、重新解包执行 Go 密码学、再次获取严格一致的双公钥；旧认证不能复用到新 cipher。
- 取消认证 1/1 通过，17.052 秒：精确 AUTH_CANCELLED，没有设备资料文件。
- AAD 保留应用/槽位/版本绑定，并在认证成功后提交；仍要求每次 CryptoObject 认证，无时间窗口或弱认证回退。私钥不经过 Dart，软件 Ed/X 钥匙不宣称始终硬件内。
- 原生测试独立包名保留原预览数据。测试 PIN、自己的 alias/文件、认证 dump 与两个新测试包已清理；原 AVD 与预览应用保留。

这六项不证明手机远程登录/审批/同步/恢复已接通。真实业务网关仍默认拒绝，真机强生物、硬件保护和 iOS 未跑。构建/原始证据位于忽略的 build/native；公开复现和边界见 [Go 桥说明](GO_BRIDGE.md)。
