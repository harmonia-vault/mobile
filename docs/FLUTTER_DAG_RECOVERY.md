# Flutter 连续恢复业务接线（实验性）

本片新增 typed 恢复投影、业务状态机和独立 `executeDAGRecovery` 原生适配；没有实现密码学、改写原包或复用旧 authority 恢复入口。UI 公开合同为 `RecoveryActions`，恢复控件另由用户指定的 Claude 编写，本片不包含视觉 UI 文件。

## 原生与业务边界

- 唯一方法参数是 `{command: String, completeCode: Uint8List}`。命令按逐操作字段白名单生成；完整码独立传入，所有成功、错误和能力拒绝路径清零可控 buffer。密码与生成码只在必要 RAM 引用中存在，不记录或落盘；Dart String 不保证彻底擦除。
- 严格解析 `issuer-recovery-dag-v1` 的固定字段、规范十进制字符串、布尔、角色和版本；未知字段、错误 profile、B3a 伪 trusted、绑定不一致或下界倒退均拒绝。变量只来自成熟 B3b 已授权 view，不进入恢复页面 metadata。
- B1 只建立受限过程。B2 新码完整重输成功只密封，必须另行明确提交。B3a 选择 1–16 个已返回的环境版本，每项显式角色和期限，没有默认全选、Admin 或永久；同原意图重试不能替换选择。
- B3a 接受与原包确认都不可信。仅 B3b 正式 Apply/Restore/Pull 的成功 binding + view 可建立可信会话，后续读取继续独立 DAG 路径。旧 authority 恢复、写入和管理能力不自动开放。
- 返回未知时保留原 ID/hash 和接受下界；原生 CAS 实际已落盘但回应丢失只能重新正式 Restore，不能推断成功。冷读取先登记元数据，再准备元数据，最后原包元数据；不根据错误字符串猜空状态。只有原生明确无本机设备时可在首次 open 中创建受保护设备。
- 本机取消同步使 Dart 晚到结果失效，独立排空原生 RAM 取消，保留持久原包。后台、Logout 和 dispose 清新码引用并退役旧结果。正式读取硬失败关闭旧明文。短暂系统认证窗口仍沿已有隐私门槛处理。

## 能力与未完成范围

`verifiedDAGOperations` 默认空，且必须和当前 `WorkflowProfile.operations`、实验 opt-in、系统强认证能力逐项相交。仅添加 Dart 代码或 runtime 广告不能打开能力；PIN、合成预览不能证明 DAG 可用。整体 `realVaultReady` 保持 false。

服务器 resolve-or-close 的桥接不在本片：查询关闭、关闭原分支、关闭后重开三个动作保持关闭，明确说明本机取消不能代替服务器关闭。中断且失去原 RAM owner 的准备记录不能被清除或重登录覆盖。恢复后的写入与设备管理也不是本片能力。

新增业务测试覆盖固定 DTO、精确两参数通道与清码、能力交集、完整显式向导、错误重输、未知原包、权限选择、原选择冻结、取消/Logout/后台晚到结果、generation/检查点变化、CAS 回应未知后的 Restore、无设备首次入口，以及服务器关闭不可用时零调用。全部使用合成输入与 fake 原生端口；不证明真实 Android 强认证、HTTPS、SDK、实际用户页面链或生产可用。
