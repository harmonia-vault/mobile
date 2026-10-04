# 设备管理、配对提示和账号重置路由

本片把已审阅的三个界面组件连接到现有业务控制器，不开放任何原生验收能力。原生 compiled 声明与逐项 verified 证据仍求交，默认 verified 集合为空。

## 账号重置

已验证服务的登录页与可信账号安全页可打开 `accountReset`。页面直接消费 `AccountResetActions`，不读取 token、签包或系统槽路径。未知结果沿原流程查询，冷查询不能准备新密码。完整结果仍是退出状态，不授设备信任。

提交清旧投影后页面继续显示原重置状态，不通过普通保险库 restore/view 回退。`proofPending` 的查询模式只提示查询，正常模式才提示明确新密码和破坏性确认。忙碌或作用域退休通知只清控件自身输入，不修改已交给原操作的局部字节；原生/Dart 操作分别在 finally 消费输入。

## 设备管理续办

设备列表通过 `ManagedAccessEntry` 进入 `deviceManagement` 二级页。只传当前 Admin 环境 ID/名称及敏感表单 scope；页面不持有目标私钥或权限证明。

准备或未知原管理操作时，`canEnterVault` 保持关闭。页面投影只允许对应的设备/管理页显示原操作 panel，环境、设置和审批页仍被拒绝。完成或合法取消后沿原正式 restore/pull 重新显示当前数据，不把原管理 metadata 当当前读取权限。

## 真实配对提示

`PendingPairingsSection` 和 `PendingPairingDetail` 使用真实 `PendingPairingHint`：PairID、发起设备 ID、状态和到期。它们不转成旧 `AuthorizationRequest`，不补名称、平台或服务器序号，不授批准权。

`VaultLocation.pairingId` 独立于旧 requestId。详情继续时只预填原 PairID；用户仍须输入完整短码，明确环境、角色和期限。导航和提交重新核本机当前已验 hint 范围及到期，已批准提示不能再次发送。手动配对保留原入口和成熟 PAKE/权限检查。

## 验证范围

纯业务路由新增三个合成场景：重置清旧显示后仍保原流程、管理 pending 只显示限定续办页、真实 hint 不伪造旧请求且状态改变后禁止审批。结合受影响账号重置/管理/pending 业务共 36 个测试通过，全文 analyzer 零问题。没有 UI 单元测试、SDK/真实系统认证、邮件发送、虚拟机或生产部署；实际产品验收能力仍关闭。
