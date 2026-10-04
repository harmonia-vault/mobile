# 账号重置与保险库控制器

`VaultController` 实现既有 `AccountResetActions`。入口只允许已验证的 HTTPS 实例：退出状态可打开独立重置页，可信设备从账号安全页进入。账号登录成功但设备尚未可信、受限恢复和演示状态不开放此入口。

`NativeVaultGateway` 创建固定 endpoint 与 scopeEpoch 的独立网关。`nativeAccountReset`、`nativeAccountResetEmailRequest` 两个真实编译声明与 `verifiedAccountResetActions` 逐项求交，验收证据默认空。普通 workflow operations 不授予重置能力。Dart 不获取 token、原签包、系统清理许可或保护槽路径。

当前已知 accountId/accountGeneration 是额外的显示范围约束，邮件结果必须匹配原账号和代际。原生仍独立核验保护槽身份。退出状态没有本机已知账号时只采用经过严格原生合同核验的邮件证明结果。

## 原请求与生命周期

申请邮件、查询证明、准备密码和重置提交始终使用同一 RAM 流程。开始后禁止普通新登录、连接切换和其它业务写入；未知结果只查询原流程。冷查询只能查询，不能准备或重试提交。取消仅退役本机 RAM 范围，不宣称服务器闭锁或物理清理。

`paused`、`hidden`、`detached`、退出、scope 变更和 dispose 同步退役范围并拒绝晚到结果。控制器保留首个取消排空 Future：重复取消和退出均等待这一次排空，失败后保持关闭门。`inactive` 沿既有系统认证遮罩规则，不当作真实后台退役；原生操作结束而尚未 resumed 时沿既有五秒表单寿命上限。真正后台改变表单 scope，UI guard 清自己控制的输入；已交付的证明和密码字节由操作在 finally 清零。

提交前 `retireVisibleAccount` 只同步撤掉旧保险库快照、账号展示和其它 RAM 投影。它不调用通用退出、不递增同一重置 owner 的 epoch、不取消正在提交的流程，也不能给原生清理回调返回 true。完整成功只来自成熟原生清理、空槽确认、服务器结果和最终排空。重置成功仍为 signedOut，`trustedDevice=false`；新账号登录必须另走正式流程。当前重置流程完成后，用户取消 RAM 流程或执行退出才释放普通操作门。

## 证据边界

本片只有合成 Dart 网关的业务测试和原生能力投影测试，不证明 Android/iOS Channel、系统槽删除或真实产品操作。界面与 `VaultPage.accountReset` 的非视觉路由已在[产品路由整合](PRODUCT_ROUTE_INTEGRATION.md)中连接；本控制器切片的业务证据不代替界面或 SDK 验收，默认能力仍关闭。
