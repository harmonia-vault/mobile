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

## 原生失效事件证据复核与续办

后续只读检查确认：本修复提交的 **34 个 Android Kotlin 生产文件**与最近普通登录/退出实际构建的对应文件逐字一致；同一 Go AAR 与两份原测试 APK 的 SHA-256 均匹配既有记录。旧测试 APK **不包含本次 Dart 控制器修复**，不能把旧产物当作修复后的产品。

既有原生记录覆盖空设备的 `NO_SYSTEM_AUTH`、系统认证成功创建材料，以及测试收尾清除合成凭据后的 SDK `isDeviceSecure=false`。它们没有读取“已有系统保护材料保留、系统凭据被移除”这一时点的生产 `localProtectionInfo`。现有驱动只断言 SDK secure/no-secure 和材料存在，不含该原生状态变更探针，因此失效事件来源仍为 **UNRUN**，不能由历史通过拼接证明。

本段未启动 AVD、服务器或构建，未设置凭据，未重跑 27 项业务测试。考虑剩余执行预算，保留如下唯一短续办：

1. 复用原任务 API34 AVD 和已核验的同一 AAR，重新核对 AVD 身份、产物摘要和 SDK 无系统凭据基线；其他 AVD 不动。
2. 在现有原生测试驱动内补一个固定探针，读取生产 `localProtectionInfo`；`systemArtifacts` 必须来自实际保护存储，不传入伪造能力或存在布尔值。只重新构建必要测试包并冻结摘要，不修改 Go AAR或扩展通用测试框架。
3. 按已有合成凭据 intent 与窗口守卫设置测试 PIN，进行一次必要的真实系统认证，创建未受信的本机保护材料；不登录账号、不发起云端业务。记录当时 `mode=system`、`systemCapability=SYSTEM_READY` 和材料实际存在。
4. 通过官方测试命令移除同一合成系统凭据；在同一材料仍存在的范围读生产状态，核对不可用资格、系统模式保持及 PIN 设置不可用。不伪造或强求某个系统结果，未知或超时按失败保留；不另开临时锁定/硬件故障矩阵。
5. 精确清理本次材料和测试包，确认 worker 排空、SDK 无系统凭据、合成 intent 已退休，停止本任务 AVD。清理不明则保留记录，不删除未知资源。该原生状态来源结果与已通过的控制器回归分别记载，仍不据此勾选整个 P4。

本段新增结果仅为源码和产物只读核验 **PASS**；原生实跑没有启动，故不是原生 PASS，也没有产生新的原生 FAIL。此前失败记录继续保留。
