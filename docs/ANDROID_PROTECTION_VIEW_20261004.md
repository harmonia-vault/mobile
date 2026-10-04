# Android 系统保护失效后的缓存视图关闭

2026-10-04 UTC；实验性软件，P4 仍未完成。

本次修正在 mobile `276301017a1f57e94d7295116ff1a7688f99c9e0` 上验证。
系统认证变为不可用时，Android 原生仍返回 `mode=system`，避免把已有系统保护材料降级为 App PIN；其 `systemCapability` 可以是 `NO_SYSTEM_AUTH` 或 `BLOCKED`。网关已有操作禁用，但控制器之前仅对 `mode=blocked`、PIN 升级要求和查询错误关闭缓存。因此上述合法原生状态仍可能显示此前解密的环境。

控制器现在也在系统模式的认证能力不是 `SYSTEM_READY` 时，沿已有暂停路径清空显示快照、退休敏感表单和待批准提示。只读能力查询恢复不能复活旧视图，不提交云端写入，不切换 PIN provider，也不删除原生持久材料。

## 定向验证

全部使用现有 Dart 合成夹具；无 UI 单元测试、真实凭据或环境扫描。

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| 修复前新增两项业务回归 | **预期 FAIL**，32.248 秒 | 两种不可用状态均已关闭网关操作，但控制器 `canEnterVault` 仍为真 |
| 修复后三份相关业务测试 | **PASS，27 项，16.502 秒** | 本机保护、前后台返回、原 ID 冷恢复；失效清空环境/设备/检查点，拒绝内部环境导航，恢复能力查询不重开缓存、不新增业务调用 |
| 改动的控制器与测试静态分析 | **PASS，16.502 秒** | Flutter 3.47.6，无分析问题 |
| 本段 Android 原生系统状态变更实跑 | **UNRUN** | 没启动 AVD、没构建 APK 或 AAR；本次只改共享控制器判断 |

命令：

```sh
./tool/flutter.sh test --no-pub --reporter expanded \
  test/native_pin_adapter_test.dart \
  test/native_lifecycle_resume_test.dart \
  test/native_restore_pending_state_test.dart
./tool/flutter.sh analyze --no-pub \
  lib/vault_controller.dart test/native_pin_adapter_test.dart
```

已验文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `lib/vault_controller.dart` | `aaaf2f0cdf5e0bc5928adf0d6d9bce2882a4b60da33f7c824b20460148a055bd` |
| `test/native_pin_adapter_test.dart` | `33c49b565381fa808e59bb6da50c94fb1816d2b82145cb1fc12bb32c85eeb564` |

## 与既有产品证据的关系

旧[受信首机、CRUD、批准 CLI 和同步](ANDROID_PRODUCT_USERFLOW_20261003.md)、[独立正式退出](ANDROID_PRODUCT_LOGOUT_20261003.md)及[原 ID 冷启动续办](ANDROID_PRODUCT_PENDING_20261003.md)均保留各自固定源码与原生库范围；不能把这些记录升级为当前快照全部通过。最近[普通未受信登录与退出](ANDROID_TRIAL_NATIVE_SHORT_20261004.md)已实际通过，本次未重跑；它也不证明当前受信手机 Boot/Pull。

本修复只在已收到不可用保护状态后关闭控制器视图，不宣称原生认证、离线授权到期、撤销和整个账号生命周期均已验收。未增加已验操作门控，未发布安装包、Release、CI/CD 或线上服务。
