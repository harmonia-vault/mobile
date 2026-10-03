# iOS 原生隔离验收

测试只使用新建的 `Harmonia-iOS-Synthetic-` Simulator、独立 bundle ID、合成账号/钥匙和本机 ephemeral TLS。不得重置、删除或复用用户旧设备数据，不读开发者账户或签名私钥。

## 构建

先按固定工具版本准备干净 BoringSSL 源码和 gomobile/gobind。显式设置 `HARMONIA_BORINGSSL_SOURCE`、`HARMONIA_GOMOBILE_TOOLS` 后执行 `mise run go-native-build-ios`。脚本要求新的输出目录，拒绝覆盖已有 XCFramework。Go 与原语产物都只在 ignored 构建目录。

`mise run ios-security-build` 构建独立 UIKit 安全测试应用，使用生产 Swift bridge/provider 源和同一 Go XCFramework；不是界面单元测试，不编入 Runner。它只进行 Simulator ad-hoc 签名，不创建或访问签名私钥。

显式提供 `HARMONIA_IOS_TEST_DEVICE` 后运行 `mise run test-native-ios`。脚本验证设备名称、UUID、已启动状态及固定测试 bundle，只安装/启动自己的测试应用；最多等待 60 秒，报告必须带当前新 runId，不能把上次结果或成功安装当作本次通过。

## 边界

- NativeSelfTest 必须由实际 Go/BoringSSL Simulator 代码运行，验证 SHA256、Ed25519、HPKE、AEAD、SPAKE2、篡改拒绝及确认重放门槛。
- Keychain 缺失项、LA 真实能力、严格错误分类、未认证创建拒绝、受保护 state 的保存/重开/畸形输入/取消均独立验证。
- PIN 组合测试只在实际 LA 返回 passcodeNotSet 时运行。其它错误如实记为 UNRUN，禁止 fake LA 或 bool 打开保护能力。
- 可在 harness 的第二个构建参数传入仅本次独立 fixture 目录：`ca.pem` 与 `private-synthetic-account.json`。它们仅复制到 ignored 测试 app，不能进入公开源码或产品 app。HTTPS 需标准 CA 链和 hostname 验证，不信任所有证书。
- 账号测试明确是 Go→HTTPS→独立 TypeScript/SQLite 的登录边界测试；直接创建的测试 Device 没有系统认证或云端可信证书，成功登录后 View 必须仍是 NOT_TRUSTED。
- 真机密码/生物识别、钥匙硬件属性、完整初始化/可信审批/恢复，以及 PIN 产品通道仍须分别验证，不由本次构建或原语测试推断通过。

## 2026-10-03 实测

Xcode 27.0（27A266a）、iOS 27.0 Simulator arm64（24A434）实际运行：**15 PASS、0 FAIL、3 UNRUN**。完整脱敏结果见 `evidence/IOS_NATIVE_20261003.json`。

- 双 slice Go/BoringSSL XCFramework 实际链接；最新产品 Swift 的 Simulator arm64 与 iPhoneOS arm64 均 BUILD SUCCEEDED。真机 slice 仅无签名编译，没有安装真机。
- 产品已在专有 Simulator bundle 实际安装/启动，原砂岩连接页截图通过人工查看；未改共享 Flutter UI，未完成 UI 账号到可信设备全流程。
- Go 原语、严格 JSON、HTTPS 证书拒绝/正确账号登录/错密码拒绝/View 仍 NOT_TRUSTED、密封 state 保存重开与取消均实际执行。
- 实际 LA 能力为 ready。调用生产 createDevice 后 250 ms 使用同一后台取消入口，最终返回 LOCKED，未授予信任，自己的受保护 Keychain 项不存在。
- 五项 PIN 组件通过：真实 Go Close 失败覆盖成功、锁释放失败与后续重开、首次保存失败清理精确 MAC 项、清理失败持久 incomplete 直到显式 forget、真实 Argon2id/MAC/限速记录重开与真实 ready 升级 latch 拒绝。组件测试只在独立测试副本追加同文件 private extension，不编入 Runner，不更改生产认证资格。
- 三项 UNRUN：实际无系统认证下的设备创建拒绝、具备真实 PIN 资格的完整 PIN 流程、真机密码/生物识别与硬件安全。PIN 产品通道和生命周期绑定仍未开放。

早期失败保留：旧 UIKit 生命周期未配置 Scene 导致无报告；测试应用缺模拟 Keychain entitlement 导致两个检查失败；把模拟 entitlement 当成宿主签名权限导致启动拒绝；测试 bundle 的纯数字日期段不符 Go package 校验导致四个组件检查失败。分别用 Scene 生命周期、Xcode 同类 `__TEXT/__entitlements` 模拟区段及合法测试 bundle 修正。没有放宽 Keychain ACL、LA 分类、Go 校验或 KDF。最终报告并不把这些失败抹去。

原始私有构建日志保留在独立任务目录，不公开个人路径、合成账号口令、邮件证明、随机 session 或密钥材料。
