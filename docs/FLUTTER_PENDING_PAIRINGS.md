# 前台配对请求提示（实验性）

`PendingPairingActions` 提供 `pendingPairings` 只读投影和 `refreshPendingPairings()`。真实行仅有原 `pairingId`、`initiatorDeviceId`、pending/approved 状态与到期时间。没有设备名、平台或服务器序号，不复用要求这些虚构字段的旧占位模型。

独立原生入口为 `executePendingPairings {command:String}`，命令只有 version、当前已选定 HTTPS endpoint、`pendingPairingRequestsV3` 或 `pendingPairingRequestsV4`。没有短码、Bearer、调用者账号、scope 或签包输入。原生 Go 每次先执行新设备验证、完整拉取和当前管理员检查，再读取请求；Dart 不拿旧视图冒充这一步。

响应严格验证版本、来源 capability、固定字段、规范十进制代际和到期秒数、最多 64 条且原 ID 唯一。账号、代际和审批设备必须匹配本机已有可信来源。`authoritativeForApproval` 必须为 false：列表永远不是授予权限的依据，也不能更改本机审批版本。V3/V4 不互相回退，DAG/P4 来源不降级到旧审批来源，冷启动未知审批版本仍关闭。

刷新替换完整快照，同一原 ID 不叠加行；过期行停止本机展示，不宣称已取消服务器请求。没有新增自动弹框、确认回执或推送服务。已有进入前台的刷新会调用新 typed 读取；旧占位通知队列不接收这些真实提示。后台、退出、账号或设备范围变化、权限降低、验证失败或读取失败清除旧提示，晚到结果不能恢复提示。短暂系统认证遮罩沿已有前台恢复规则处理。

原生返回 `LOCAL_PROTECTION_PERSISTENCE` 时，本机保护状态不能确认：清除可信来源和审批版本，撤回旧保险库展示，并保持清理闭锁。此时登录和恢复可信会话都不可用；只有已确认的原生退出清理才能解除闭锁，之后仍须重新登录与授权。普通网络失败仅清除请求提示，不因此撤回已有离线授权。

选中请求只能把原 pairingId 带入现有 `ApprovalDraft`。用户仍须完整短码、明确环境/角色/期限，最终批准始终使用现有已验管理员配对流程。approved 行只表示请求提示中的状态，不表示本机获权或对方已完成入网。开始实际批准时移除旧列表，结果不作乐观改写。

平台编译标记 `nativePendingPairingRequestsV3` / `nativePendingPairingRequestsV4` 缺失视为 false，再与独立 `verifiedPendingPairingOperations` 相交。后者默认空；编译存在不会自动开放按钮。系统强认证、当前可信 Admin 来源、本机保护模式、端点、清理和未决操作门继续执行。

本片只有 Dart 非视觉业务和合成测试。没有实现原生 SDK、UI 控件、后台推送或普通工作流 fallback，也没有声称生产可用。实际 Android MethodChannel、系统认证和 UI 验收由对应任务另行完成。
