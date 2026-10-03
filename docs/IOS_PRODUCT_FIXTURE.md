# iOS 独立产品 HTTPS 测试配置

此路径只服务本机合成测试，不授予账号或设备信任。Flutter 界面、controller、Go、Android 与服务端源码均未改动。

## 配置边界

只有 Swift 同时编译 `DEBUG`、`HARMONIA_PRODUCT_FIXTURE`、Simulator target，且包标识精确为 `org.harmoniavault.ios.productfixture` 时，原生桥才读取 `HarmoniaProductFixture.json`。资源只有 `endpoint`、`caPem` 两字段；地址固定 `https://127.0.0.1:5593`。普通构建或 Release 若误带该资源，原生桥初始化拒绝。

构建脚本限制输入大小、拒绝重复字段，只接受单张公共 CA，使用系统 OpenSSL 验证自签名、CA 和签发用途。运行时以 Security.framework 校验证书结构与有效性。该评估只使用本次局部 trust 对象，不写系统 trust store。

`fixtureConnectionInfo` 复用现有 Flutter 四字段合同。Flutter 在原有系统根基础上追加本次公共 CA，Go 仅通过既有 `openWorkflow(...additionalCA:)` 追加该 CA；没有关闭 TLS 链或 hostname 验证。三条 workflow、approval、enrollment 路径共用认证前的固定 endpoint 检查。普通构建的 `additionalCA` 仍为空。

独立 Simulator 包使用 `HARMONIATEST.org.harmoniavault.ios.productfixture` 本地 Mach-O entitlement 和 ad-hoc 签名，不使用 Developer 账号、发布签名私钥或真机签名。`realVaultReady`、PIN 与其它未验收能力仍关闭。

## 复现

先使用独立空实例 fixture，在自己的 5593 端口创建临时 TLS 与合成数据库；CA 私钥与 leaf 私钥仅留该进程内存。不要复用其它平台的端口、账号、数据库或邮件。

```sh
bash tool/ios-product-fixture-build.sh <Flutter3.47.6目录> <本次公共fixture.json>
bash tool/ios-product-fixture-gate-test.sh <自己的Simulator-UUID> build/ios-product-fixture/HarmoniaProductFixture.json
```

构建脚本不会安装产品包。门槛脚本安装并运行三个独立 `org.harmoniavault.ios.fixturegates.*` 测试包；应在已经协调好的测试窗口时段执行，Simulator 启动错误可能弹出系统提示。它不调用系统认证、不读取钥匙、不创建账号，逐次核对 run ID，不能将旧报告当成本次结果。

## 2026-10-03 实际结果

基线为 mobile `9e0a00b81ebe08b203d79ee246b434412c5a67fb`，服务端 `bd86fec6215b6f7149234578e7bf5dc764a639c2`。Xcode 27.0、iOS 27.0 arm64 Simulator；固定已构建 Go XCFramework 和成熟 BoringSSL 依赖。

- 配置组件：1 个有效配置、11 个无效配置拒绝、4 个 endpoint 判断通过。此组只覆盖 `decodeResource` 与 `acceptsWorkflow`。
- 实际 `fromBundle`：三个独立 Simulator 包通过普通无资源返回 nil、普通含资源拒绝、Debug 定义但错误 bundle 拒绝。
- 正确 bundle 的接受路径在真实 Flutter 产品中运行：初始化原生桥、取得 fixture 合同、标准 HTTPS 连接成功，进入要求邮件验证的“创建账号”页。该证据只证明连接，未注册账号或授予信任。
- 最终 Debug Simulator 产品编译、安装和启动通过；普通 unsigned Release iPhoneOS arm64 编译通过，产物没有 fixture 资源。Release 没有安装到真机或发布。
- 此轮账号注册、邮件证明、登录、首台初始化和管理操作尚未执行。以前的官方模拟认证两项 PASS 属独立测试，不计入本轮产品流程。

最初测试小包缺 Scene 生命周期导致启动失败，修正测试入口后重跑上述三个门槛全部通过；没有改动产品认证或安全策略。公开证据保留最终源码与产物哈希；本机保留初版排障记录。Simulator 结果不代表手机硬件、生物识别强度或真机安全验收。
