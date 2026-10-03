# iOS 官方模拟认证补充验收

2026-10-03 UTC，生产桥固定 mobile `9e0a00b81ebe08b203d79ee246b434412c5a67fb`，五个生产 Swift 文件逐字归档，使用既有固定 Go/BoringSSL XCFramework。仅新增独立 Simulator harness，不加入 Runner，不改变 Flutter、Android、生产 capability 或 PIN 入口。

Xcode 27 的官方界面是 Device Hub。实际选中本任务专有 iOS 27.0 arm64 Simulator，通过 `Device > Face ID > Enrolled`，待系统面容 ID 界面出现，再执行 `Authorized with Face ID`。没有注入 LA 返回值、私有通知、改宿主认证或安装系统 CA。

实际结果为 2 PASS、0 FAIL、1 UNRUN：

- 生产 `createDevice` 经真实 `evaluatePolicy`、`WhenPasscodeSetThisDeviceOnly + userPresence` Keychain 保存及 72 字节回读，Go 结果 `trusted:false`。
- 生产 `executeUnlocked(publicInfo)` 使用新 LAContext 重新取钥并导入 Go；同一 deviceId 且 `trusted:false`。
- 真实手机密码、生物因素及硬件保护仍未测。一次官方模拟匹配后，新 context 读取直接完成，不能将这项结果表述为第二次独立物理认证成功。

结束时只删除本次独立 bundle 的精确 Keychain slot，已验证不存在；不重置模拟器。`realVaultReady=false`、`appPinReady=false` 保持。此前 15/0/3 安全结果单独保留，本次不覆盖其统计。

## 有界复现

先按既有 iOS 构建文档生成固定 XCFramework，再执行 `bash tool/ios-official-auth-build.sh <Flutter3.47.6目录>`。仅向显式指定、名称为本任务专有的已启动 Simulator 安装 `build/ios-official-auth/HarmoniaOfficialAuth.app`；不要对 `booted` 别名或其他设备批量操作。通过上述官方界面完成模拟认证。

harness 每项最多等待 90 秒，超时走同一生产背景取消方法。结果写到自身 Documents/official-auth-result.json，须比对 app 中 HarmoniaHarnessRunID.txt，不能把安装/启动当通过。已有自身 slot 时拒绝复用，不删除未知资料。运行报告与截图均不输出钥匙或合成账号凭据。

本次补充还没有验证 Flutter 产品注册、邮件证明、初始化或恢复流程。后续独立 HTTPS fixture 必须采用 debug 固定 endpoint 与局部追加公共 CA，标准 hostname/证书链验证保持，release 禁用；不改变系统信任根。

原运行 source/binary/runId 保留在证据中。公开 harness 随后只把已执行操作的超时、SDK 异常或不符结果改记 FAIL；未将原二项 PASS 重新归属到修改后的产物。system 不可用和真实手机因素才保留 UNRUN。
