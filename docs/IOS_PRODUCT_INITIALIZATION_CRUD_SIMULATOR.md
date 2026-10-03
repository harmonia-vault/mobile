# iOS Simulator：首机初始化与最小变量 CRUD

2026-10-03 UTC，在固定公开 mobile `8a0515c374dea6bd29e966e442c804b2222db7a7` 的独立 Debug Simulator 产品构建中，实际完成同一合成账号登录、显式首机初始化、公开测试变量新增/读取/更新/删除，以及正常退出后的本地恢复拒绝。第一次超时流程的两次实际失败单独保留；没有将后续成功覆盖为“全程无失败”。

这份记录只覆盖 iOS Simulator，不能证明真机生物因素、Secure Enclave 或每次独立物理认证。完整机器可核对摘要见 [JSON](../evidence/ios-product-initialization-crud-20261003.json)。此前固定 9e 产品的注册/邮箱证明记录保持独立，见 [注册记录](IOS_PRODUCT_REGISTRATION_SIMULATOR.md)。

## 固定输入与构建

- mobile：`8a0515c374dea6bd29e966e442c804b2222db7a7`；所有归档 tracked 源文件与构建目录复核一致，没有本轮 UI/controller/Android 修改。
- Go：`b094a933bf1922347b4a41ea8baaa5699ffbf5c1`，复用已固定 XCFramework；BoringSSL：`fab96f87245d7c6b941515201843665122650b88`；server：`bd86fec6215b6f7149234578e7bf5dc764a639c2`。
- Xcode 27.0 (27A266a)、iOS 27.0 (24A434) Simulator、iPhone 17 Pro 模型、Flutter 3.47.6。
- Debug 构建实际成功并安装到原测试 bundle，保留自己的既有本地状态。Runner SHA-256：`691f30d606f27fa92238086b191ad761477d2e04ca09b57a5eb618edf187b9a7`；Flutter kernel：`7dfb132759d365f8c931996b7fb54ae4f8ed171ae9115a4307a89201da5ddede`。
- 仅本次 `https://127.0.0.1:5593` 独立合成 HTTPS 服务；沿已审 DEBUG/显式 define/Simulator/精确 bundle/endpoint 门槛局部追加测试 CA，保留标准证书链及主机名验证，未更改系统根。
- 本轮未重跑 Release 或既有安全 harness，不追认后续公开提交为已执行产物。

## 实际结果

| 操作 | 结果 | 可核对证据 |
| --- | --- | --- |
| 原账号登录 | PASS | 页面仍为未可信设备，不能访问环境。 |
| 第一次首机完成 | FAIL | 完整 52 字符重输后实际返回 `REJECTED`；初始化接受计数为 0。 |
| 第一次原 ID 查询 | FAIL | 现有查询按钮实际调用一次，仍为 `REJECTED`；未在此步骤生成新意图。 |
| 显式退出并重新登录 | PASS | 通过正常产品退出清理本机 pending/钥匙，同一账号重新登录、新本机钥匙、新首机意图。 |
| 第二次首机初始化 | PASS | 生成、官方 AX RAM-only 读取并隐藏、完整真实键入及提交合计 6.464 秒；服务器接受 1 次，真实 Boot/Pull 后进入初始环境。 |
| 新增并读取变量 | PASS | `IOS_SYNTHETIC_CHECK=public-value-one`；产品返回详情并读回同值。 |
| 更新并读取变量 | PASS | 同一变量改为 `public-value-two`；产品读回同值。 |
| 删除变量 | PASS | 正常显式确认删除，页面显示 0 变量。 |
| 正常退出及恢复拒绝 | PASS | 回到登录页，再点本机恢复入口明确提示设备钥匙不可用，云计数无新增。 |
| 测试服务清理 | PASS | RAM 输入助手与 HTTPS helper 均 exit 0，5593 拒连接；键盘捕获关闭，Simulator 保留。 |

所有变量均为本测试明确创建的公开字符串，不是用户环境变量。恢复码仅在官方 AX 助手内存中短暂读取并立即隐藏，随后通过正常键盘完整重输；没有写剪贴板、输出恢复码或绕过完整重输。前两次 AX 定位因同一元素的重复引用失败，均在展示恢复码之前停止；`CFEqual` 去重后成功。连续输入日志的 `startedUTC` 字段实际是在助手结束时记录，因此时限结论只使用 6.464 秒单调时钟持续时间。

## 服务接受与同一 Pull

下表是同一独立服务的累计计数。初始化本身的环境标签写入为 environment 1/1，不算环境管理 CRUD；本轮变量 create/update/delete 恰为 mutation 3/3。

| 阶段 | init accepted | mutation attempts/accepted | boot accepted | pull accepted |
| --- | ---: | ---: | ---: | ---: |
| 第一次失败后 | 0 | 0/0 | 0 | 0 |
| 第二次初始化后 | 1 | 0/0 | 2 | 5 |
| 变量新增后 | 1 | 1/1 | 4 | 10 |
| 变量更新后 | 1 | 2/2 | 6 | 15 |
| 变量删除后 | 1 | 3/3 | 8 | 20 |
| 最后退出及恢复拒绝后 | 1 | 3/3 | 8 | 20 |

最终 register 1/1、emailProof 1/1 延续此前合成账号；login 4/4 包含两次显式登录和两次首机流程重新验证账号密码，不能记为四次人工登录测试。各步写入后经原有 Go 验签下发和产品投影读回，没有向 UI 注入 trusted 或绕过云成功门槛。

## 保留的失败与范围

第一次 pending 页面停留约四分钟，超过 server 固定 120 秒挑战期限。过期是结合时间和源码得出的推断，原始 Go 详细错误未捕获，实际可观察分类为 `REJECTED`。夹具只有固定 16 项公开计数，没有初始化 GET 次数或 HTTP 状态，不能补称查询网络次数已实测。

固定 Go `mobileworkflow/vaultworkflow.go:641` 先发原 ID GET，在 `:651` 才校验响应；`:614` 拒绝过期的 pending，但完整 complete 回执允许挑战期限已过。固定 server 的 `initializationStatus` 返回原 pending 记录而没有明确 expired 状态。因此这里是过期 pending 的产品状态/重开入口缺口，不能描述成“已接受但结果未知无法查询”。保留原失败后，本次按现有明确退出/同账号重新登录路径重新开始，未改 TTL、未手删保护文件、未重置或新建 Simulator。

重新登录的官方系统认证后曾短暂出现“先恢复应用入口，再执行此操作”。正常进入首机页后可继续，作为独立观察保留，不声称已修复生命周期问题。截图本机时钟显示约 19:35–20:05，文件时间对应约 11:35–12:05 UTC；旧私有失败摘要的 UTC 注记已用单独 v2 更正，原始冻结未删除。

这次 8a 流程只观察到新设备创建时一次官方 DeviceHub Face ID 匹配。后续实际使用原生新 LAContext 和受 ACL 保护的 Keychain 路径，但没有额外可见认证提示，不能算每次独立物理因素验证。PIN 产品入口和整体 `realVaultReady` 默认门槛保持关闭。

真机、PIN 产品链、CLI 配对/跨设备批准、恢复轮换、恢复后设备登记、额外环境管理 CRUD、重启/离线/撤销耐久性不属于这次验收。最后正常退出没有删除云保险库；随后只停止自己的合成服务和 RAM 输入助手。公开候选仅本文及脱敏 JSON，截图、构建产物、CA、私有路径和秘密均不发布。
