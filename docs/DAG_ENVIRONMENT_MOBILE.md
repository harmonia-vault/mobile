# 已恢复设备的环境管理接线

独立环境域提供 `createDAGEnvironment`、`renameDAGEnvironment`、`rotateDAGEnvironment`、`deleteDAGEnvironment`、`pendingDAGEnvironments`、`retryDAGEnvironment`。它不扩充普通 writer、DAG 恢复或变量四操作白名单。MethodChannel 只有 `command` 与独立 `name` 字节缓冲；名称最多480个UTF-8字节、去空白后1–120个Unicode字符，不含NUL。名称不放进命令、pending元数据或日志，发送与失败路径消费并清零字节缓冲。

创建必须显式选择当前已验 Admin 环境作为 authority；没有默认第一个 Admin，也不能借用另一环境权限。重命名、轮换、删除都逐次检查目标环境 Admin。Dart 只表达用户意图，密钥生成、接收者集合、恢复封套、原签包、权限和检查点均由 Go 正式业务处理。

成功需要 `environment` 原请求元数据和同次正式 Pull/CAS 后的已验 `source`，绑定原账号、代际、设备、恢复登记ID/摘要/接受序号及不倒退检查点。UNKNOWN不应用视图，不生成替代请求；仅依据原生返回或查询确认的原ID续办。两个域的pending合并展示但分别分派，任一域未解决时阻止新共享修改；跨域重复ID拒绝。已应用历史条目不被误判为未完成事务，metadata查询本身不授设备信任。

Android 独立 typed dispatcher 复用变量域的逐次系统 CryptoObject、owner/epoch、整份密封状态CAS、取消和worker排空流程；加入所有同级分派的busy条件、前后台/锁屏生命周期、账号重置drain与销毁。默认 `verifiedDAGEnvironmentOperations` 为空；运行时profile或compiled声明不能自行开放业务。全局ready继续关闭。

现有环境页面调用创建/重命名/删除控制器入口，另提供 `rotateEnvironmentKey(id)`。新建表单使用以下业务合同：`usesDAGEnvironmentAuthority`、`dagEnvironmentAuthorityChoices`、`dagEnvironmentAuthorityId`、`selectDAGEnvironmentAuthority(id)`。选择初始为空；非Admin选择拒绝；账号或本机来源退休时清空。用户指定的本机Claude单次生成 `DAGEnvironmentAuthoritySelector`，已机械接入 `lib/ui/harmonia_app.dart` 的 `_EnvListState`／“新建环境”HSection。仅DAG来源显示选择控件，非DAG不新增占位或空隙；无有效选择由原错误状态拒绝创建。现有环境详情的轮换按钮仍待UI增量。

验证边界：Dart非视觉传输、控制器、会话安全合同，以及Kotlin请求封装的纯JVM检查。没有绑定新AAR，没有使用伪造Go ABI编译Android，没有执行JNI、系统认证、模拟器或Flutter用户点击链。环境管理、完整恢复向导及整体安全可用性必须以之后统一构建和实际业务验收为准。
