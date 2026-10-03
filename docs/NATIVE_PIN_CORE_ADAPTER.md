# 私有 PIN native core 适配候选

当前候选未接 Plugin、UI、MethodChannel、正常 Go AAR 或能力开关。Android 真正 PIN 解锁和批准 CLI 仍未跑；主机 5 项合同测试不构成 Android 资格、Keystore 与 Go 合体验证。已有独立 Android 存储 5 项证据与本候选不同。

## 范围和真实 ABI

仅新增 `pinlocal/NativePinCoreAdapter.kt`、`PinNativeSlot.kt`、独立主机测试与工具/本说明，不修改已公开的 classifier、MAC store、LocalPinProvider、共享 Workflow、Plugin、Gradle、GoMod 或 AAR。

Go 来源是公开 `core-go1544501fe6b1637d3cbe49d347c39a56ee344fe1` 的 PIN 包装器；Java ABI 已由固定 `golang.org/x/mobile v0.0.0-20260908204917-8b95e45f8d3e` 的 gobind 实际生成并用 Java17/API36 编译。没有猜测 Kotlin 对 Go 接口的转换：

- `Mobilebridge.newLocalPINSetup(package, namespace, slot, endpoint, LocalPINLifecycle)`、`openLocalPINCore(..., protectedScopeJSON, lifecycle)`。
- `LocalPINCore.scopeJSON/create/execute/executeApproval/executeEnrollment/cancel/close`；execute 全部以 `byte[]` 接 PIN、完整 command、record、密封 state、native CA，审批/入网另接当次短码。
- `LocalPINStore.acquire/release/commitAttempts(long,String)/loadAttempts()/saveWorkflowSealed(byte[])`；异常会跨 JNI 回 Go，失败不能发 lease。
- `LocalPINLifecycle.retireOwners()` 只能同步退役独立 native slot owners，不能重入本次 core 的 Close/Execute。没有 RawMaterial、任意 Sign 或 lease 导出。

gobind 自带零值 proxy constructor 不得使用；本适配只调用正式 factory。生成 Java 的编译验证不会加载旧 AAR 的 JNI，也不证明候选 AAR 运行。

## 每次操作

`NativePinCoreAdapter.prepare(context, fixedPinSlot, mode, retireOwners, fixedNativeCA, shortCode)` 返回 native-only `NativePinOperation`。固定 configuration 由原生账号 slot 配置提供，不接受 Dart 路径、alias、双 pub、许可 bool、fake NONE 或保护上下文。`PinNativeMode` 只选择成熟 command 方法；Go 再核完整 intent、原 ID、endpoint 与 operation，mode 不是认证。

factory 先取得固定 slot 全业务锁，再读真正 Android 系统 classifier。setup 必须 NO_SYSTEM_AUTH 且 PIN slot fresh；已有系统模式钥/状态由成熟 LocalPinProvider 拒绝。正常操作先用实际 Keystore MAC 读 scope/record/limiter，升级 latch 或 BLOCKED 都拒绝；SYSTEM_READY 持久 latch 后永久拒绝旧 PIN 业务。取消、认证失败、临时锁定、未知能力从不降级。

`provision(pin, fullReentry)` 调成熟 Go 新身份/双录 KDF，再由成熟 store 单事务发布 record+limiter，核验固定 scope/初始 revision 读回。早 setup 失败同步关闭临时 Go core、退役独立 owners、精确清理只属于 fresh 本 PIN slot 的 alias/packet/limiter/state。若系统/存储清理失败只报 PERSISTENCE，不声称 durable 清理已完成。

`execute(pin, completeCanonicalIntent)` 是一次性调用。APPROVAL/ENROLLMENT factory 接 native 当次短码字节，其后立即擦原输入，execute 后擦私有复制；Go 分别调用成熟 ExecuteApproval/ExecuteEnrollment。Recovery 入口在公开 Go PIN wrapper 明确关闭，不移用系统 Recovery RAM owner。

整个操作持固定业务文件锁；Go 内另取成熟猜测尝试锁，MAC fresh Load → durable precharge → Argon2/AEAD → durable settle → 成功 Release → private one-use lease → Import/成熟 Workflow/同 pull/save → Close。跨实例业务 BUSY 不进入 Go、不 charge/KDF；猜测尝试和业务锁分别覆盖猜测串行及完整状态事务。

正常状态文件是 `noBackupFilesDir/harmonia/app-pin/<slotID>.workflow-pin-v1.gcm`；slotID 与 MAC store 完全一致，绑定 actual package/namespace/slot。Go 的密封 namespace 另绑定 endpoint/mode/gen/epoch/双 pub；不能移用系统状态文件。读取时捕获原密文 SHA256，每次保存核相同摘要并更新新摘要，AtomicFile/fd.sync/目录 fsync/精确读回后才返回。孤立 `.new` 拒绝；合法首次未有 Workflow state 由成熟 Go 的空上下文门槛处理，缺 MAC/limiter 绝不初始化为零预算。

业务结果仅来自成熟 Go；`requiresDeviceDeletion:true` 触发先同步退役 RAM，再删除该 PIN slot 的 MAC alias/packet/limiter 和密封 state。任何删除失败均不返回完整本地退出成功；不碰系统 provider、preview UID、其它 slot 或云 vault。`forgetLocal` 不要 PIN、不解包旧钥，清相同固定 slot 后只有新身份重授权，不能复活旧 identity。

provision/execute 自身在返回前关闭 Go/core/provider 并释放业务锁。关闭或释放失败覆盖候选成功为真实失败；`use/finally close` 仍建议作为 native 调用纪律且重复 close 幂等。Cancel 先禁本次 save、同步退役 owners，并保证尝试取消 Go，即使退役回调本身失败也不略过取消。

系统升级实际迁移仍未实现，必须正确旧 PIN 加真正 CryptoObject，原子切换前保持闭合。本候选不会自动迁移。软件 PIN 保护不抵抗低熵离线猜测或 root 完整旧快照回放；Java/Go/JNI/AES/KDF 内存复制无法宣称全部硬擦。

## 候选 AAR 计划（未执行，先经父任务审阅）

1. 在新私有 temp 目录仅 archive 上述 public core154 与固定 public mobilec18598a850b23971ad362cb724c0f903828dbc28，加本有限候选。不得混 live 工作树或改产品 AAR。
2. 固定 Go1.26.4、Java17、SDK API36、NDK28.2.13676358、gomobile/gobind 固定版本。新 GOPATH/GOCACHE/输出均在 temp；复用已缓存模块，不安装新工具或自动变更 GoMod。
3. 只读核验原生 BoringSSL 上游 `fab96f87245d7c6b941515201843665122650b88` clean，然后复制固定 Android lib/include 到 archive 的 ignored native 路径。当前已核静态库 SHA256 为 `9a8f776f1b3e9f5a0b04f082094752d1938acabb06883279f4c7b8c961ee86ab`，库 29,786,648B；复制前后再核 manifest。上游本机 clean 固定源码存在，未发起下载或重编译。
4. 独立 `gomobile bind -target android/arm64 -androidapi 30 -javapkg org.harmoniavault.go -tags harmonia_boringssl -trimpath` 写到新 temp AAR。原正常 `harmonia-go.aar` SHA256 `7af225529d2d5cea6c435e28f568e7d3a3cd523688ed8a966be16dd1dfed1e08` 前后须不变。
5. 新独立合成 Android 包使用候选 AAR 和这 5 PIN native classes，不接 Flutter/Plugin。manifest 精确审阅后仅需要与真实产品相同的正常认证权限才能读 classifier；有权限后仍须实际 verdict 为 NO_SYSTEM_AUTH 才能测 PIN，若 BLOCKED/SYSTEM_READY 则如实阻塞，不改系统 PIN/时钟或伪造 NONE。实际 native slot/BUSY/CAS/清理及真实 HTTPS PIN 批准 CLI 产品测试必须单独记录，通过才考虑下一产品接线。
6. 实跑由父任务安排 AVD 窗口，baseline 新 package 不存在才安装，只卸载本次新包/alias/slot并核原包/AVD/PIN保留。没有 Release、部署、真实凭据或宿主环境变量测试。

## 本轮证据

实际 gobind Java source generation PASS；Java17/API36 ABI compilation PASS。首轮失败是 sandbox 默认 Go cache 写入被拒导致空输出，以及其残余源；换私有 cache/全新输出后 source generation 成功。Java 独立编译最初缺 android.jar，加入真实 API36 后成功，均未回避安全设置或加载 JNI。

最终固定 Kotlin2.4/API36 编译与主机 5 项 PASS，原始日志/用时在冻结清单。5 项只覆盖 scope duplicate/unknown/跨 slot、整数溢出/必需字段、原密文与 hash、真实 Java 跨实例文件锁、状态 CAS/边界；provision向量只是公开元数据，不能作为真实 AEAD/material 或认证资格。

Android JNI、实际有权限 classifier、MAC+Go合体、PIN批准CLI、候选AAR构建、Plugin/UI产品能力均 UNRUN/CLOSED。
