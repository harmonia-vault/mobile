# Android 非空 B1/B2 原生接线证据

2026-10-04 UTC，固定 API 34/arm64 隔离 AVD 的一个真实 SDK 组件通过，耗时 11.029 秒。四次系统设备密码 CryptoObject 依次完成设备创建、打开非空恢复 owner、准备新码、完整重输后密封原 journal。没有 Flutter 点击，也没有授予可信设备状态。

三个业务操作使用独立认证票、slot owner 和 AtomicWorkflow；平台生命周期 epoch 与 Go RAM registry 跨认证保持一致，operation epoch 各不相同。sealed 返回的原事务标识/摘要格式及 pending 元数据、非空环境与三份变化后的本地 AES 加密状态包均实际核验；没有额外比对底层 journal 的 ID/hash。严格 HTTPS 代理实测 challenge/session/authorityChallenge 各一次成功、vault 两次成功，transition POST 为 0。

产物使用 core `b06302c`、mobile `09d3ce4`、server `36ab16f`、protocol `038f2db` 固定公开归档，加原已审 public Channel 有限覆盖。AAR SHA256 为 `641cadc8d74b2cb7260a612ddd1ccf3882cab3f4dfb7ed67063cd935b1f00db3`；本轮只修夹具 Activity 的既定 SLOT 参数，不修改原生安全 decode、Go 或 AAR。编译 SDK 36 与实际运行 API 34 分开记录；不是当前最新整树验收。

finally 正式清除本轮合成系统 PIN，独立 Keyguard SDK 确认无设备凭据；两专用包、自己的 forward 已清，原包集一致。确切 Node 子进程正常退出、SQLite 关闭清理标记与 4471 端口释放均通过，既有 AVD 数据保留且 VM 未停止。

旧失败保留，包括空 forward 列表解析拒绝，以及上一轮已完成业务断言但夹具错误 SLOT 导致清理失败的整轮 FAIL。不能追认这些历史整轮通过。设备密码这次通过，不代表所有停止/后台时序分支覆盖。B2 提交、结果不明续办、B3 入网激活及 Flutter P1 产品流程尚未在此组件运行。

精确产物、代理计数与清理结果见[脱敏证据](../evidence/android-dag-b1b2-sdk-20261004.json)。
