# Flutter 设备管理业务接线（实验性）

本片只连接成熟的六个普通设备管理操作：`managementDevices`、`prepareDeviceGrant`、`prepareOtherDeviceRevocation`、`managementInfo`、`retryManagement`、`cancelManagement`。复用既有 `NativeWorkflowAdapter`；不重写 V3 PAKE 审批、不新增视觉 UI、不在 Dart 持有 bearer 或直接请求服务端管理 API。

`ManagementActions` 是最小 UI 合同，所有动作按 typed presentation 的能力与原状态门槛使用。设备列表显示真实 deviceId、角色、授权期限、钥版本和授权代次；不补造设备名称、平台或服务端序号。

准备授权需要明确环境、目标设备、角色和期限。`none` 表示移除此环境授权；其它设备全局撤销是单独的破坏性确认，并且不能用于本机。服务器仍逐次验证管理权及全环境撤销条件，Dart 的当前 Admin 显示不能替代授权证明。

准备成功仅密封原签包；用户必须明确提交。同一原操作只使用首次生成的 ID 与原包，不乐观修改目标角色或删除设备。unknown、accepted-not-applied 都保留原 ID 和接受下界；只有确切 prepared 且未尝试提交才允许取消。取消回应丢失只能沿原 ID 查询原历史，不能猜未提交。已接受且最后本机保存失败不能伪装 applied。

变更完成或取消确认后，重新正式 restore/pull 再显示当前权限。本机自降权、真实 TRUST_INVALIDATED、Logout 或管理操作在途进入后台，会清理旧列表/表单并阻止晚到结果重建会话。原准备信息的 `expiresAt` 仅为 revoke 请求证明期限；它不是设备授权期限，grant 冷元数据也没有所选角色/期限，不据此推断。

新增管理能力必须满足运行时 profile 与独立 `verifiedManagementOperations` 的交集；后者默认空，PIN/预览不能开放。恢复 DAG 来源仍完整禁止走这组旧 Workflow 操作：成熟 `checkWithoutManagement` 对该来源拒绝，DAG 全局撤销权源也尚未接通，不能因为数据字段相似或显示 Admin 就解除此限制。

前台待审批列表的 server v3/v4 HTTP 合同只有账号代际、版本、能力和请求快照（PairID、发起设备 ID、状态、期限）。本片不伪造 name/platform/sequence，也不开放旧 placeholder；需要独立成熟 Go/原生只读桥和同源实际证据后再接。列表只提示，实际授权继续已有明确短码 PAKE 流程。

附带一个 P1 状态表述窄修：纯本机 `restoreDAGRecoveredDevice` 不证明联网，显示为离线缓存已验；只有实际 Apply/Pull 成功才显示在线。操作来源通过内部 callback 传递，不新增调用者可信布尔或改变原生 DTO、公开恢复 UI 合同。

测试是合成非 UI DTO/gateway/controller 测试，不能代替真实 Android 强认证、管理服务、CLI 权限约束和实际页面验收；P2 产品项仍未完成，整体不宣称生产可用。
