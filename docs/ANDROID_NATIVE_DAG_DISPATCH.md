# Android 原生 DAG B 分片候选

本片没有打开 MethodChannel、Flutter profile、B3 登记、PIN DAG 或普通保险库访问。所有结果 `trustedDevice=false`。静态编译和 Go 测试不能证明真实设备密码、跨认证恢复 owner 或服务端原包续办已经完成。

## 固定来源

候选底座为 core-go `af702df5aca99913ec47aa23bbdb8c4b1f681bb8`、mobile `85f8c6c116d7a0efcf7d8321c8c6caf63fabafcf`，叠加已冻结 A 文件，再叠加根已审的 `LoginDAGAccountScope` 单一生产 helper。该 helper 随后公开于 `36054c37c64028ce6232facaaefd19a251e46894`，字节未变；A 随后公开 core `acf369c`、mobile `9f49125`。产物是上述精确归档加候选，不能称为最新公开整树验收。完整 hash 在候选输入和最终冻结 manifest 中。

## 原生入口和 DTO

只有 native 内部 `executeNativeDAG`，通道没有对应方法。JSON 必须是唯一字段的扁平对象：`version:1`、固定规范 HTTPS `endpoint`、`operation`；只有 `openDAGRecoveryOwner` 接受 `email`、`password` 两个字符串。完整码使用独立 1–512 字节当次缓冲，只在 open、seal、cold query 接收，其余操作必须零长度；码不得写 JSON、日志或磁盘。现有 JSON 上限 32768 UTF-8 字节。

封闭操作为 open、ownerInfo、preparationInfo、pendingInfo、begin、seal、retry、queryOriginal，另有仅本槽 RAM 的 `cancelDAGRecoveryOwner`。后者保留密封 journal，不声称服务器已关闭或原请求已接受。没有 rawSign、任意原包、外部 authority、provider、registry 指针或 caller auth bool。

Sequence、acceptedSequence、expiresAt 使用规范十进制字符串，避免 uint64 在 Kotlin/JSON 数值转换中截断。pending/preparation/query 只返回成熟 Go 生成的有限元数据。begin 的完整新码仅当该次前台且当次认证票仍有效时回到 native consumer；本片未提供 Flutter 显示入口。

## 原 scope 与每次认证

平台 generation 由 native 随机正整数启动并在真实生命周期撤销时推进。每个 `NativeSlotOwner` 自己提供 operationEpoch，两者不混用。正常每次 Flow.Close 只 detach；跨调用只保留 opaque Go registry。每次认证重新取得完整槽快照及 FileLock，准备新的 CryptoObject、解包 72 字节软件材料、导入新的 Device、打开新的 typed AtomicWorkflow、attach 同一原 registry；不保存或复用上次 Device、provider、Workflow、接收私钥或 cipher。

`open` 先由高层 `LoginDAGAccountScope` CAS 保存公开 account/generation 并更新 Go/桥双 SHA，再调用成熟 Open。helper 仅允许 fresh/clean untrusted scope。已有 DAG journal 或 preparation 必须按成熟原包/原 owner 合同处理，不能重新登录、清记录或改 ID 后重新开 owner。桥禁止 Export/save 更新哈希。

每个 domain 调用都有 registry.reserve/finish；finish 先于原生 drain 和 Close。Attach 与 cancel 使用一致的 cancelMu→registry.mu 顺序，避免先持 registry gate 再等取消 gate。立即失效只 cancel/invalidate；Go Close 和文件 owner release 在 worker 排空后执行。

## SDK 设备密码与强生物

使用实际 SDK `BiometricPrompt`，允许 `DEVICE_CREDENTIAL | BIOMETRIC_STRONG`，认证成功必须是本次同一 Cipher。只处理 Activity SDK lifecycle 与系统 SCREEN_OFF，没有 Dart foreground bool 或系统 package 豁免。

受控 AUTH_WAIT_STOPPED 最多 30 秒仅保留不可使用的票和 RAM；此时不导入材料、不发 HTTP、不进行 CAS，也不交付结果。真实同一 callback 成功后仍必须等 SDK resumed 且 Keyguard 未锁，等待最多 5 秒；正常业务最多 30 秒且不延长成熟 Go owner/server 截止。HOME、屏幕关闭、超时、取消、失败、退出、dispose 或保存异常令旧 generation 和所有原 ctx 永久失效。可观察 SDK 事件不能完美识别所有 stopped，设备密码的真实顺序必须在后续 API34 验收中核对。

本地取消/认证失败若 SDK 从未 pause，不把已观察前台改成 false；因此可用新的真实 Cipher 再认证。它不会复活旧票。paused/stopped/HOME/ScreenOff/锁定仍清前台观察。回调或结果先到时不会自行构造 resumed。

## 清理和当前结果

每个 native completion 只执行一次；所有清理步骤分别尝试，任一释放/Close 不明永久闭锁，不能假报本地取消完成。普通 create/logout 和 PIN 路径先撤销本槽 DAG RAM；PIN 不支持此 DAG 分片。public normal profile 的 ready 标记保持原值。

首轮新增 Go 测试编译失败为合成 fixture 字段名称错误，已保存，未改变生产 gate。随后 target race、bridge 全受影响 race/vet、正常 arm64 AAR 与 Kotlin/API36 结果以最终 manifest 为准。旧 A、旧 all-writer 和产品流程的 FAIL/PASS 保持原范围，没有回头重跑或追认。

真实 JNI、系统设备密码、Android APK/runtime、B1 真 owner 跨认证、B2 断网 unknown/retry 均未运行。不得据 host 11 项纯生命周期测试宣称这些能力已验收。
## B v2 独立审阅修正

v1 关闭错误仅影响当次错误返回，未把 Flow.Close、Device.Close、文件 owner.Close 的不明结果加入永久清理闭锁。v2 用同一个私有 NativeDAGCleanup 逐步执行清理：任一步异常粘性闭锁本 dispatcher，后续清理继续尝试，推进平台 generation 或后续成功清理不能复开。closeCaptured 当前只是清空字节缓冲和引用，没有 I/O；同样单独保护其异常，避免阻断其后的 Device/owner 清理。

v1 的 complete 停止 timer 后，异步释放可能越过原 deadline 仍交付完整新码。v2 交付时严格检查原票 deadline；不延长认证、操作、Go owner 或服务端期限。释放晚于或刚到原截止时拒绝结果并撤销原 RAM registry，密封 journal 保留。交付前在主线程重新读取清理闭锁。

独立审阅的 v1 两项纯时钟 FAIL 保持原证据；v2 复用完全相同测试验证操作与认证两种原截止。新增清理逻辑 host 用例只证明实际共用门控及剩余步骤执行，不声称实际 JNI Close 故障已经注入。v2 仅 Kotlin/host 有限变化，Go 与 AAR 沿用冻结 v1 字节；没有新的 Go/AAR 构建或 Android/设备认证运行结果。

## 最新公开基线的根整合复验

随后根将本片精确源码叠加到 core-go `952f853f20ce40f6c9211e2fe54d6b103195b8fd`、mobile `9f491258162244f9a9acec194794454c795d04a5`。mobilebridge 包 51 项 race 通过；同一初始命令另含不存在的 `mobilebridge/nativeowner`，因此命令整体失败，该错误完整保留。修正路径后只运行尚未验证的 internal/recoverysessions 包，14 项 race 通过；两实际包 vet 通过，没有重跑已通过的 51 项。

最新核心重新生成 arm64 AAR 通过（6.859 秒），SHA256 `e9f9ac29bab8bab06202bf22e652ea753081e33c431e85ee0db514a030918fee`；真实 Java ABI、API36 与 Kotlin 编译通过（5.154 秒），三个 host 入口合计 17 项通过（0.143 秒）。首次绑定因离线 module cache 缺元数据失败，修正为已核验的专用缓存后通过，源码没有变化。二进制只用于本地测试，不发布安装包。

这些结果取代“v2 未重新构建”的历史范围描述，但不追认旧产物。真实 Android JNI、系统密码、跨认证恢复 owner、B2 服务端续办与 Flutter 仍未据本片完成验收，能力开关保持关闭。
