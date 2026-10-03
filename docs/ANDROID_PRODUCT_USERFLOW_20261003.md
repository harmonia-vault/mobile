# Android C 实际产品主链（4461）

本次 **核心产品主链通过，完整测试脚本仍 FAIL**。149.966 秒内实际完成 34 次系统设备密码认证；不是 35 次。最后 `finalTrustedLocalLogout` 等待新的系统认证窗口得到 `SELECTOR_UNAVAILABLE`，不能据本地测试清理追认产品退出成功。

## 实际通过范围

- 实际 Flutter 连接页验证标准 HTTPS / Harmonia 空实例，注册、邮箱证明、退出后正常登录；登录仍未获得设备信任。
- 首机初始化显示新完整恢复码并在设备 RAM 中完整重输；Go 真实双签初始化、原生包封装、Boot / 验签 Pull 后实际环境列表。
- 已选 C 界面真实导航、变量创建／编辑／删除／再次创建，环境创建／重命名／删除。
- Android 真实手动批准正式编译 CLI 默认 **证书 3**，明确唯一初始环境、读写及 1 小时期限。PAKE 短码仅当次 RAM；没有版本自动降级。
- CLI 双签完成、真实 daemon Boot / 验签 Pull，读取 App 已写变量，沿固定请求 ID 写入；App 沿原配对 ID 继续并再次真实 Pull，界面实际显示 `SYNTHETIC_CLI`。

公开计数：初始化接受 1、邮箱证明接受 1、审批尝试／接受均 1；环境接受 4（初始化重命名 1 + CRUD 3），变量 mutation 接受 5（App 4 + CLI 1），Pull 接受 74。原始固定阶段和全部公开计数保存在 [公开阶段与计数](../evidence/android-product-userflow-20261003.json)，不含值、凭据或原生保护上下文。

## 精确输入

生产 mobile 快照为公开 `ac1e872ce138ee8000837a24141ad8900200c8c7` + 已公开的三个表单修复文件，Android/Dart 编译输入对应 `8a0515c374dea6bd29e966e442c804b2222db7a7`；其他后续 HEAD / iOS / PIN 变更不计入产物。

| 输入 | SHA-256 / 固定来源 |
| --- | --- |
| controller | `40daa50302109001b299aa5246a6e3d855d4e143491750a6272cff8dec74cd07` |
| C app | `a5e22f7ef45af793019497e75bc1459f9f1d0e9fe3cd7d7a7f3eed1a5c0195f0` |
| 表单业务回归源 | `18c5d6783e3069c96b7d664b9953a8ce8c3fd3c526a7970e3435ee2134b1b8b5` |
| AAR | `fb9664f6ccc13707367a12e64f28663fc17018ff4d8bb044ea37d913be2e1d0b`，公开 core `b094a933bf1922347b4a41ea8baaa5699ffbf5c1` |
| CLI | `65db0778666bdc98469e32f774d54e3fb699f4e2b29f9f0e5fb4a32be87745f0`，纯公开 b094，`-buildvcs=false` |
| APK | `affeb86800b6c5fb0f9d7de3d3c9e0e0a8d94e42f012e52cd7debb7672ac57ee` |
| test APK | `354da057e06453e7bc225b911f9898018dfb283465e4a25323adec857a031f0b` |
| 有限 SDK 驱动 | `85b49a472e4104ede9f607966b129fbfc2859a5cbee1ca7801c596f92d33ffc6` |
| RAM host | `70f5d4bf921b2e5213351fb9540cfbff82f91dd925f14487a8ca13890083e92b` |
| 4461 公共配置 | `50e45faaf9cff1a9452397a6973730d0de8d72c9919ab04d5609267d9603af5f` |
| 实测输入 manifest | `e2f4d0991e8e550ab212f9f1a8640e74f959c8de76c1553e482f3a6a02540ef6` |

服务来源为公开 server `bd86fec6215b6f7149234578e7bf5dc764a639c2` 的新空 SQLite fixture及有限 TLS helper `2aa7463c28e3470766922683b595a8c8d3ed9b0343da43676f6ba39c096dafe3`。临时 CA 私钥只由 fixture 进程持有；每个 APK 严格绑定固定地址和公共 CA，维持正常 chain/hostname 验证。

驱动只用正常 SDK 可见节点、真实 touch/key / accessibility 点击及有界滚动；点击、填写目标严格唯一，等待真实目的页、勾选与 enabled 状态。两个明确合成内存预验（32 / 33 帧）只证明测试定位，不计作授权或 CLI 产品通过。

## 未通过步骤与清理

尾段未观察到预期的新认证窗口，实际退出结果不明。当前现场已 finally 清理，因此不凭源码、页面标题或资源卸载推断退出成功；应另做最小可信 scope 的正式退出回归，不重复全部 CRUD。

本次官方同 RAM PIN `clear` 返回 0，实际 SDK finally 确认 noSecure；CLI 自有 provider／进程／目录清理成功，ADB forward 已移除。随后精确卸载本人 `.productfixture` 与 `.productfixture.test`，终止本人跟踪的 4443、4445、4447、4449、4451、4455、4457、4459、4461 fixture（各端口实际无监听）。原 preview APK SHA `4d3efb2d745734664a28f1725855eb73da8b963f5bfea2884668de0a88611c66` 与原独立 AVD 保持，live 7af AAR 未改。清理证据 SHA `fbd935107631c5cc2b724a87ebbb40bc84863952793060f700e5d00341cfac02`。资源清理不是产品退出通过的替代证明。

早先 93.089、126.749、114.978、123.196 秒真实失败和相应源码／APK／阶段计数均保留；本轮没有追认旧失败。实际 Android API34，compileSdk36；实验 gate 的整体 `realVaultReady=false` 保持，不能把本轮算作 PIN、恢复/V4 或其他平台通过。
