# PIN 原生 Go JNI 隔离验收

2026-10-03，在新建的官方 Android 34 Default ARM64 模拟器上，五项 Android instrumentation 全部通过：测试耗时 **2.286 秒**，包含冷启动、安装、执行和清理共 **23.704 秒**。普通 `USE_BIOMETRIC` 权限已真实获授，真实系统分类为 `NO_SYSTEM_AUTH`；没有设置系统 PIN、修改认证能力、传入能力布尔值或降低系统认证门槛。

这是独立 PIN provider/Go 包装器的验收。Plugin、Flutter UI 和产品能力仍未接通。正确 PIN 解包后调用成熟 Go `view`，新设备仍必须返回 `NOT_TRUSTED`；本轮没有账号登录、CLI 批准、云端写入或恢复操作。

固定源码为 core-go `1544501fe6b1637d3cbe49d347c39a56ee344fe1`、mobile `c18598a850b23971ad362cb724c0f903828dbc28` 加五个独立 Kotlin 适配/host 测试/合同文件，BoringSSL `fab96f87245d7c6b941515201843665122650b88`。Go 1.26.4、NDK 28.2.13676358、Android API 30 arm64 AAR 构建通过（14.486 秒）；独立 APK 编译通过（初次 9 秒，真实分类 runner 更新后 5 秒）。安装目标镜像为已装官方 Android 34 Default ARM64 revision 2/extension 7，未下载新镜像。

| 真实用例 | 核验结果 |
| --- | --- |
| 正常权限与真实系统分类 | `USE_BIOMETRIC` 获授、Keyguard/BiometricManager 的 `NO_SYSTEM_AUTH`，不伪造 NONE；其他分类在 runner 前关闭测试入口 |
| JNI 创建、错误 PIN、正确 PIN与新实例持久计数 | 真实 Argon2id/AES-GCM 设备材料包；错误 PIN 拒绝并保留 precharge；revision/total 从 1/0 → 2/1 → 4/2，成功 settle 后才进入 Go；正确 PIN 仍 `NOT_TRUSTED` |
| whole-business 独占 | 第二实例 `BUSY`，PIN 尝试 total 仍为 0；首次操作完成后新实例才可进入 |
| Android 持久状态 CAS 与精确清理 | 真实 no-auth Keystore HMAC、AtomicFile/readback 与固定 slot CAS；外部修改后拒绝保存。此项公开 opaque 测试包只证明 CAS，不作为 AEAD 成功或云端可信证据 |
| 忘记 PIN 与早期 setup 失败 | 精确删除本 PIN slot 的 alias/packet/state，完整双录不一致不能创建 identity；重新 setup 的双公钥、AuthGeneration、KeyEpoch 均变化，仍需重新入网授权 |

五项均使用本任务生成的合成 PIN、随机新 slot 和无网络权限的独立测试包。PIN、材料、lease、密封状态和钥匙没有记录到日志或导出至 Dart。错误 PIN 目前由成熟 LocalPinProvider 将 Go 认证错误闭合为固定 `BLOCKED` 类别，未将其伪报为成功。

| 产物 | SHA-256 |
| --- | --- |
| 独立候选 AAR | `f5950beaa64adee637c577fc804255c874a60516238263f956001900b76183db` |
| 独立 target APK | `609e92890f70673e175e44d68d2d055ef753395a8cf849bfb6763192dca9d227` |
| 独立 test APK | `c7167a8baaf2f5022685cea76cb125df19eb6c53246187135873d05e24295391` |

测试后两个专用包均精确卸载，171 项 stock package 基线完全相同；新模拟器停止并保留目录，现有模拟器继续运行，正式 AAR `7af225529d2d5cea6c435e28f568e7d3a3cd523688ed8a966be16dd1dfed1e08` 未变。已有 ADB server 只用于明确新 serial 的正常 transport，没有重启 server、读取或重写用户 ADB keys、改 HOME 或使用跳过认证参数。

前两次准备执行真实失败并保留为 `UNRUN`：一次因 SDK 工具将新 AVD 索引写入另一私有目录导致 emulator 未找到；一次因 macOS `/var` 与 canonical 路径别名，两个预定空目录尚未建立。两次都未安装 APK、未运行 JNI；之后仅修正同一任务新 AVD 的索引查找和原定私有目录准备，原测试、包、权限与认证门槛完全不变。本轮首次真正启动后的五项全部通过。

软件 PIN 仍有低熵离线猜测风险；无认证 Keystore HMAC 用于持久记录完整性，不能称为用户认证或对 root 级完整旧快照回放的防护。KDF、缓冲区清理不能保证 Go GC/AES 内部全部内存被硬擦。系统升级需 durable latch 与真实系统认证迁移；产品升级、恢复 RAM owner 接线、忘记 PIN 的完整业务入口及 **PIN 批准 CLI** 尚未完成，不能据本轮宣布生产可用。

AVD 私有目录采用 Android 官方的 [SDK 与 emulator 环境变量](https://developer.android.com/tools/variables)隔离方式；发布仅包含源码、合成测试与脱敏证据，不包含 APK/AAR、临时签名 JKS 或 ADB/模拟器认证文件。
