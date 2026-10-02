# 和弦 Harmonia — 手机端

Flutter 手机界面与 Go 核心之间的手机适配边界。Android 为首版目标，保留 iOS 源工程。当前是实验实现，不可用于生产秘密。

## 已实现

- 中文 Material 3 界面：环境与变量编辑、设备角色/期限选择、恢复轮换重输与结果查询、HTTPS 地址与登录入口。
- 显式合成预览中的环境/变量 CRUD、只读限制、检查点倒退拒绝、提交后拉取更新；无网络或文件持久化。
- 默认路径拒绝真实读取、登录、批准、撤销和恢复，不发送密码或短码。
- Go/JNI 密码学桥与系统设备密码或强生物认证的 AES 包封；Android14/API34 隔离 AVD 实际六项原生验收通过，真实业务网关仍未接通。

## 本机开发

使用官方 Flutter **3.47.6**（Dart **3.13.5**）、Java **17**、Android SDK 平台 **36**。`tool/flutter.sh` 校验 Flutter 精确版本；`pubspec.lock` 固定依赖。工具版本在 `mise.toml` 固定，Flutter 默认由 `mise where flutter@3.47.6` 解析，也可用 `HARMONIA_FLUTTER_SDK` 显式指定同版本官方 SDK。`mise run android-debug` 先构建固定 BoringSSL/Go AAR，再构建 Flutter APK。NDK28.2.13676358 须先安装；任务不隐式接受许可证。SDK、Java 与 CMake 本机路径仅写入忽略的配置文件。

```sh
mise run deps
mise run analyze
mise run test-domain
mise run android-debug
```

`mise run preview` 仅在主动选择测试模拟器后使用。合成预览必须显式传入 `--dart-define=HARMONIA_PREVIEW=true`；不传时默认拒绝真实操作。不要输入真实邮箱密码、恢复码或生产秘密。

测试证据与未跑项目见 [验证记录](docs/VALIDATION.md)。控制层测试属于业务边界验证，不包含 UI 单元测试。Android 调试产物只用于本机测试，不公开发布。

## 未完成

窄 Go 原生桥及设备密码包封已实测；首次可信手机、远程 SPAKE2 批准、真实服务器验签同步与恢复原子轮换尚未接入 Flutter 业务网关。强生物成功与硬件保护未在真机验收，iOS 未构建运行。界面入口不代表这些安全能力已实现，合成预览不能撤销任何真实设备。

[整体技术设计](https://github.com/harmonia-vault/workspace/blob/main/docs/DESIGN.md) · [Go 桥边界](docs/GO_BRIDGE.md) · [界面设计](DESIGN.md)

MIT 许可证。
