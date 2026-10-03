# Android 产品原ID冷续办实际验收（2026-10-03 UTC）

本轮 4469 单次实际流程 **PASS，83.527秒**。这是已修产品业务层在真实 Flutter widget、Go AAR、标准HTTPS与每操作系统认证上的原ID冷续办验证，不是完整CRUD/CLI矩阵重跑。此前4465取消FAIL、4467续办入口隐藏FAIL及其原始产物均保留，未追认通过。

## 实际结果

新空实例注册、邮件证明、首机完整新码重输、真实Boot/Pull作为前置通过。代理只让一笔真实accepted mutation的响应丢失；Android先显示未知结果并读取本机原journal ID。真实force-stop后重新连接同地址，双Back取消首次系统认证：未解锁、保护材料仍存在、业务计数不变。

随后成功恢复的同次已验证账号范围携带不可变pending元数据。controller保留现有闭锁续办入口，不自动Pull隐藏原ID。原ID冷启动前后一致；用户明确沿原ID查询/继续后，由Go原journal完成验签与保存，再经正式Pull显示合成变量名称。mutationAttempts=1、mutationAccepted=1，明确续办没有第二mutation POST。合法verified只读Pull可以显示已接受的数据；这不等同原ID已解决或乐观更新。

最后从C设置页正式退出通过；本地设备/工作流材料不存在时prepareOpen拒绝。实际18次成功凭据输入、1次取消符合预期；finally官方清除本次合成系统PIN，并由实际SDK确认noSecure。两专用包、forward、自有HTTPS/Node账号库fixture均清理；原预览包SHA、原AVD数据/进程与live 7af AAR保持。

## 精确来源

手机底座是公开 `1cb839883577f6a23a78408112198424cb2b437f`，仅覆盖 `lib/vault_controller.dart`、`lib/native/native_vault_gateway.dart` 与新增业务测试。controller `577f4863...`，gateway `aadb20c4...`，test `71c25214...`。C视觉与组件未改。相较此前8a实际来源的三处public PIN能力变化另有私有源差分；本轮只验证systemStrong路径，不声称PIN重测。

复用公开core `b094a933bf1922347b4a41ea8baaa5699ffbf5c1` 的固定AAR `fb9664f6...`，没有重新构建Go或追认最新PIN/DAG源码。新空库来自公开server `bd86fec6215b6f7149234578e7bf5dc764a639c2`；有限TLS helper `2aa7463c...`，标准证书链与hostname验证，无SkipVerify。三份driver与4467字节相同；host仅端口/配置及冷恢复3→2次认证变化。新公共CA使本轮两APK字节独立，分别 `bf30da21...` / `987ad365...`。compileSdk36，实际Android14/API34、arm64-v8a。

业务回归先红后绿：8项新增场景、全98项测试通过（进程8.894秒），最终静态分析无问题（报告1.9秒，进程2.796秒）。最终分析采用独立 `analyze-final-result.json`，不是早先2.715秒的记录。双原ID逐笔续办、不可retry正常恢复、取消、账号/代际替换及退出迟到结果均为合成业务回归；本轮实际只一笔pending mutation。

[完整脱敏证据及源码/产物SHA](../evidence/android-product-pending-20261003.json)。证据不含宿主个人路径、PID、账号标识或秘密。两张近似Settings画面仅留私有，不重复上传。

overall `realVaultReady` 仍false；本轮不新增DAG、恢复或PIN能力，不增加新的CRUD/CLI矩阵承诺。
