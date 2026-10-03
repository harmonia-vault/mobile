# 原生创建意图的两存储边界（候选，Android 未运行）

基线 mobile ecbbc621 / core 6d8178。仅本机原生包封流程；不增加 Dart、云端或可信设备状态。

固定字段为 version=1、package、workflowSlot、deviceFilename、baseAlias、generation（随机16字节的小写32位hex）、kind（generation/legacy）、phase（prepared/ready/retiring）、packetSHA256/workflowSHA256（空或64位hex；retiring绑定原设备/状态包，残留同对象逐件核对）。字段按固定顺序以长度前缀编码，单包 AndroidKeyStore HMAC-SHA256 认证；metadata key 无系统认证要求，仅保护元数据，不能解包设备或授予保险库权限。

1. 全部本槽位材料为空且没有未知旧包封 alias 时，先验证或创建固定 metadata MAC alias，再发布 prepared intent，完成 AtomicFile/fsync/readback。若在 metadata alias 创建后崩溃，仅当设备/状态/PIN/intent 均不存在且 key 的 generated/HMAC256/no-auth 策略精确匹配，明确 create 可复用此 metadata key；它不是包封 AES key。
2. intent 发布后才创建精确 `baseAlias/setup/<generation>` 每次系统认证 AES-GCM key。不扫描或删除 alias 前缀。prepared 无设备包时，取消或下次明确 create 可消费该已认证意图的清理票，删除仅这个 alias/intent/metadata alias；随后新 generation、新 CryptoObject。整个清理仍校验 captured 完整快照。
3. 108B 设备包保存并读回后，将 locator 标记 ready 并绑定该密文 SHA256。locator 持续保留，供以后查找 generation alias。若设备包已保存而 intent 仍 prepared，不能删包或猜提交结果；下一次真实系统认证解包、Go验证材料后才补 ready。ready 的包摘要变化拒绝。
4. 已有设备删除先发布 retiring（精确原 generation alias/密文摘要）再销毁包封 alias、设备及本槽位状态，最后删除 locator 和 metadata key。中断续清只接受原 retiring intent 及仍存在包的精确摘要；新快照变化或结果未知不自动清理、不刷新旧 expected。
5. 旧108B/baseAlias格式可正常认证读取，不复用未知 baseAlias 作为新创建。旧设备显式删除可在本次已认证 owner 下发布 kind=legacy/retiring 的精确清理意图；它只授权删除，不升级为新设备或其他 generation alias。

全部 intent 原子包、metadata alias 和所指 wrapping alias纳入 common snapshot。cancel/dispose 令操作 token 失效；正常跨认证的宿主生命周期 generation 与每操作 token 分开，本片不宣称 B1/DAG registry 已接线。finishWrite 后读回异常可能已提交，必须退役并报告不明，不能笼统保证旧包保留。

发布开始（包括 finishWrite 自身）后出现异常，不调用 failWrite 猜测回滚；保留可见 locator/设备包并退役 owner。fresh owner 必须先同步已核固定文件和原目录，确认 FD 关闭，再捕获完整持久基点。只存在未验证/不同对象的记录仍拒绝接管；这不替代 MAC、系统 CryptoObject 或 Go 材料验证。
