# 手机业务网关接线与局部 TLS 测试

本批将 Flutter 控制器接到明确的 Android 原生意图。密码派生、设备材料、签名、密文、可信证书与服务器事务继续由 Go / 原生实现；Dart 不持有会话 token，不保存密码、短码、恢复种子、密文签包或私钥。当前仍是实验性软件。

## 公开业务边界

普通首屏仅 HTTPS 服务地址，实际 `/instance-info` 响应验证产品身份、公开协议兼容性和注册开关。`HARMONIA_NATIVE_EXPERIMENTAL` 必须显式选择，网关逐操作同时检查运行时 profile 与独立 Android 证据名单；运行时自报能力不能替代测试。整体 `realVaultReady` 继续为 false。

账号注册投影仅账号 ID、generation 与邮箱证明要求；登录成功仅账号身份，不能读取保险库。需要证明邮箱时进入独立证明页，公开 challenge ID 与邮件一次 token 输入经原生意图提交；成功后仍进入未可信的首机向导。尚无原生重发邮件意图，入口关闭。证明回应丢失时只允许用原正确账号凭据正常登录确认，不假造证明成功。

首机恢复码由原生随机生成。用户必须完整重输，原生验证并完成持久密封后，再以真实 `restoreSession` 和拉取建立可信界面。本次明确首机路径使用 V3 审批；冷恢复投影没有来源证书版本时关闭审批，不猜公钥、文件头或自动降级到 V2。

可信恢复只接受原生认证后的账号、generation、设备绑定和严格视图。共享写入先提交云端，再通过相同拉取流显示；没有乐观权威变更。写入结果未知会隐藏旧保险库视图，查询有限六字段事务元数据，再以原 ID 续办；不替换 name、value、ID 或重新签包。批准的 `approved` 仅说明管理设备已批准，仍等待新设备 `complete`；按原 PairID 查询或续办，不用新短码重签，已 POST 的审批不能随意取消。

退出先阻止新意图并隐藏缓存，真实原生清理确认后才允许换服务。异步原生结果必须匹配当前 scope epoch、地址和明确审批版本；旧账号晚到成功或取消错误不能复活审批，也不能解除新账号未知事务的门槛。

## 仅调试构建的 HTTPS 测试边界

`HARMONIA_PRODUCT_FIXTURE` 默认关闭。公开提交 `c18598a8` 中的独立 Android `.productfixture` debug flavor 从 ignored 固定构建配置注入唯一 loopback HTTPS 地址与公共临时 CA，公开零参数 `fixtureConnectionInfo` 投影。手机 Dart 只给该地址的局部 `SecurityContext` 追加公共 CA，标准证书链和 hostname 验证继续生效。没有全局 HttpOverrides、badCertificateCallback、系统根安装或地址绕过。MethodChannel 不接受任意 CA；构建证明不授予账号或设备信任。

默认正常网关不会调用测试证明方法。release、错误 flavor、远程地址、包含私钥的 PEM、未固定的地址均拒绝。测试 CA 私钥只在宿主临时测试目录生成并销毁，未入源码、产物或报告。

## 本批实际验证

本次四能力切片的 Dart 控制器、严格 DTO、业务映射与 TLS 合计 **68/68 通过**，`flutter analyze --no-pub` 通过（1.8 秒），无 UI 单元测试。其中 6 个 TLS 测试使用本机临时合成 CA 和真实 HTTPS 服务，分别验证无 CA 拒绝、固定地址正常连接、错地址请求前拒绝、受信 CA 不绕过 hostname、错误构建标记与秘密 PEM 拒绝、正常网关没有测试能力而明确夹具能连接。另两条平台生命周期观察测试验证敏感表单进入真正后台后清空、系统认证窗口 inactive 不清空，以及 dispose 后不回调已销毁输入；未渲染 UI。其余测试使用明确合成原生端口，不证明 Go、Android 系统认证或安全操作真实成功。

覆盖完整新码错误重输、登录与设备可信分离、邮箱证明仍未可信、未知写入原 ID、批准与完成分离、已 POST 不取消、原 PairID 续办、退出/换服务后晚到审批成功或取消，以及旧写入取消不能清除新 scope 等待状态。此前独立 IA 的默认与演示 APK 证据见 [信息架构验证](UI_IA_VALIDATION.md)，不能替代本批新网关点击链。

## 四项原生能力的独立证据

`loginAccount`、`restoreSession`、`businessPendingInfo`、`retryBusinessOperation` 已加入默认证据名单，依据公开 [core-go `32b02936`](https://github.com/harmonia-vault/core-go/commit/32b02936fe24de9e6b7d5da1100c158b7a89b3eb) 与 [mobile `c754a59f`](https://github.com/harmonia-vault/mobile/commit/c754a59f135f8ed1f64f6b9abf5b01c7f68347a5)。同源 Android 独立三阶段 **3/3 通过，62.370 秒**，包含 22 次 CryptoObject 和两次真实 force-stop；原生完整记录见[账号与事务合同](NATIVE_ACCOUNT_PENDING_ABI.md)。此结果证明这四项原生意图的有限行为，不证明 Flutter 产品点击链完成。

默认名单只有在显式实验选择、当前运行时确实支持、profile 版本已知及系统强认证可用时才生效。新增功能测试验证：已公开的四项能力可以进入操作门槛；仅运行时自报、缺少运行时支持、未知 profile 或系统强认证不可用仍拒绝。登录成功继续不授予设备信任，公共测试 CA 也不授予信任；冷恢复缺少来源版本时审批仍关闭。原 ID 续办、晚到响应隔离及全部既有负例继续通过。整体 `realVaultReady` 不变。

## 尚未验收

原生局部 TLS 注入的编译与构建边界已有公开源码，当前 Flutter 对真实空实例的注册、首机、CRUD、系统验证批准 CLI 点击链仍未跑。公开地址持久化、冷启动自动解锁恢复、设备请求原生列表、对端设备管理与 PIN provider 仍有独立能力缺口；不得用合成预览宣称完成。
