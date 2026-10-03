# Android 本地 PIN 产品纵链：实际通过与保留的失败

固定公开源码的 MainActivity NativeBridgePlugin、Keystore、Go JNI、合成 HTTPS 及真实 CLI3 三阶段已全部 PASS：19.937、9.756、7.754 秒。实际完成 PIN 批准、子设备入网、正式 daemon Boot/验签拉取/读写，以及忘记 PIN 后新设备仍未可信。此结果不是 Flutter 用户点击验证；公开默认 PIN 云端业务仍关闭，下一独立候选逐操作启用后另测用户输入主链。

源码固定为 mobile `0caf1d094fbabaa7233902ff7b8cc5559bd93a2e`、core-go `b094a933bf1922347b4a41ea8baaa5699ffbf5c1`、server `bd86fec6215b6f7149234578e7bf5dc764a639c2`。共享 AAR SHA `fb9664f6ccc13707367a12e64f28663fc17018ff4d8bb044ea37d913be2e1d0b`。本轮 CLI SHA `65db0778666bdc98469e32f774d54e3fb699f4e2b29f9f0e5fb4a32be87745f0`，350 个公开文件逐字节匹配，固定原生库 SHA `6be8fd170b3d6a944b12e51ceacf994405f73c06e9780065ecc5598f72fca7d2`，显式 `-trimpath -buildvcs=false`。旧 CLI `2fc93e20` 的源码也匹配，但 Go 采集了上层仓库 dirty 元数据，原证据保留，未改写其 manifest。

| 完整业务运行 | 第一阶段 | 第二阶段 | 第三阶段及整轮 |
| --- | --- | --- | --- |
| 初次 | PASS 19.711 秒 | PASS 9.782 秒 | public socket readiness 夹具失败，整轮 FAIL |
| 固定 stage/EOF 诊断 | PASS 19.798 秒 | PASS 10.934 秒 | CLI HTTP 前拒绝未规范 `/tmp` 祖先，整轮 FAIL |
| 规范路径及纯公开 CLI | FAIL 8.044 秒，真实资格 BLOCKED | 未跑 | 未跑，整轮 FAIL |
| 原预算显式刷新实际资格 | PASS 19.937 秒 | PASS 9.756 秒 | PASS 7.754 秒，整轮 PASS |

三次完整 FAIL 均保留，不能用最后成功覆盖。另一次单独只读资格诊断 PASS 8.005 秒：API34、deviceSecure=false、combined=11、strong=11，mode=none、无设备或 PIN 残留、NO_SYSTEM_AUTH。该只读结果当时没有设置 PIN 或调用云端，不能独立代表产品通过。第三轮当时缺少原始系统数字，仍不能确定其 BLOCKED 成因。

零网络 CLI 存储 preflight 证实：未规范化 `/tmp` 路径精确触发成熟 ErrPermission；规范化 `/private/tmp` 路径通过本地存储检查，随后停在缺少登录参数。只修夹具 `resolve(strict=True)`，没有放松祖先 `O_NOFOLLOW`。

最后一轮只在 test01 业务开始前按原 30 秒 monotonic 预算，显式刷新生产 `localProtectionInfo` 并逐次记录固定元数据。实际第一次即为 NO_SYSTEM_AUTH/none/无设备或混合残留。既有设备、混合残留或升级 latch 会直接拒绝，超时仍失败；没有修改分类器、资格、权限、系统 PIN、时钟或能力默认值。

| 已实际覆盖的入口/操作 | 证据 |
| --- | --- |
| localProtectionInfo、setupLocalPIN | 第一阶段真实资格、双录、错误 PIN 拒绝及持久延迟 |
| register、verifyEmail、loginAccount | 合成空服务的真实注册/邮箱验证/登录，登录仍未可信 |
| beginInitialization、completeInitialization、restoreSession | 完整新恢复码重输、实际签名及验签下发后才可信 |
| businessPendingInfo、retryBusinessOperation、setVariable | 服务接受但丢响应，实际 force-stop 后原 ID 恢复，没有第二次提交 |
| createEnvironment、renameEnvironment、deleteEnvironment、deleteVariable | 第二阶段真实在线 CRUD 与同一验签下发流 |
| approvePairingV3、retryApprovalV3、pull | PIN 批准真实默认 CLI3 单环境限时 RW；先 approved，子设备完成后才 complete/序号 |
| forgetLocalPIN | 清 PIN 所属本机材料，新双录生成不同设备 ID 且仍 NOT_TRUSTED，再精确清理 |

CLI 使用真实 PAKE 和正式命令，验证单环境入网、后台新 Boot/验签 Pull、读取 App 创建值、在线原 ID put 并通过同一下发应用。服务最终公开计数：注册/邮箱验证/初始化/批准各 1，变量写入 4、环境操作 4；批准请求仅 1 次，没有把 approved 当作 complete。

尚未验证 Flutter PIN 用户输入/取消/忘记点击。未覆盖的 PIN 操作包括 queryInitialization、approvalInfoV3、cancelApprovalV3、V4、恢复、迁移、环境钥轮换、已有设备权限管理与 PIN logout；这些不能因整体 ready 字段而开放。不是生产可用声明，软件 PIN 保护边界仍见本地保护说明。

每轮均精确卸载本人两个测试包，原有包名基线一致，本人启动的 AVD 退出 0 并保留磁盘目录。本人 HTTPS helper 已关闭，最后一轮 CLI、临时目录和转发均清理。未改 ADB server/钥匙、其他 VM/账户，也未部署、发布安装包或替换正常 AAR。
