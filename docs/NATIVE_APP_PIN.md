# 独立 Android App PIN 持久适配

本切片仅增加三份独立 Kotlin 类、有限测试和本页合同。没有修改 NativeBridgePlugin、Gradle、Go wrapper、Flutter UI、AAR 或能力开关；`appPinAvailable=false`。PinNativeCore 是待桥接代理实现的私有转换接口，没有现成实现，不能据此启用 PIN 业务或宣称生产可用。

## 私有接口

`PinNativeCore.scope` 是固定 native `PinScope`：package/namespace/slot/规范HTTPS endpoint、mode=pin、独立随机AuthGeneration/KeyEpoch及精确Ed/X公钥。新scope来自Go-owned临时新Device的公开metadata；私钥只在Go，create成功与失败都须关闭临时Device。既有scope须先验证本slot Keystore MAC，不能从Dart bool、目录pub或登录成功建立信任。

`create(pin,reentry)` 只返回规范Go `Record.Encode()`密文字节和初始AttemptState。`execute(pin,completeCanonicalIntent,snapshot,store)` 在Go内重新严格DecodeRecord、固定KDF/AEAD与双pub核对，原ctx单用Lease.consume后ImportDevice执行既有typed workflow，结束CloseDevice；只返回公共result，不返材料、localVaultKey、lease、任意签名或token。PIN/intent作为独立ByteArray，本Kotlin provider在结束时清调用方缓冲；Go/JNI/privatewrapper还须清各自副本，不承诺GC或所有内存副本硬擦。

`PinDurableStore`固定acquire/release/load/commit(expectedRevision,next)。Go adapter将完整AttemptState严格转换为有界JSON/ByteArray，字段与公开Go包一致，uint64超过Long.MAX_VALUE必须拒绝，不截断或用Double。MAC已验证不代替Go现有账号/设备回执、来源、当前授权、原请求ID和native最终保存门槛。

## 资格与单调模式

生产PinCapabilityClassifier只读取真实KeyguardManager与BiometricManager。API30+且Keyguard不secure，combined强生物/设备凭据和strong两项都精确NONE_ENROLLED或NO_HARDWARE，才是NO_SYSTEM_AUTH。SYSTEM_READY表示本次可用强生物或设备凭据；矛盾/unknown/HW_UNAVAILABLE/security-update/unsupported/tempLockout均BLOCKED。系统认证取消/失败不是能力缺失，没有传入本classifier的fallback参数。纯PinCapabilityPolicy只用于有限分类测试，provider不接受调用方snapshot或fake-NONE bool。

新设置只在NO_SYSTEM_AUTH和本机全新身份/slot进行，完整PIN重输和密码学约束仍由成熟Go包核验。已有SYSTEM的本机key/state文件、备份或Keystore alias存在就拒绝PIN设置；固定映射由native adapter提供，不能从Dart传路径/alias绕过。不同模式切换都须明确本地清理/新身份，不自动把旧SYSTEM钥移入PIN。

已有PIN检测到SYSTEM_READY时，先在原slot whole-attempt锁下把MAC envelope的upgradeRequired=true原子同步落盘/readback，然后拒绝业务。标记不改Go AEAD binding或AttemptState；一旦观察到true，同进程拒false回退，重启仍从MAC包读true，即使系统配置后来移除也拒PIN。真实正确旧PIN+CryptoObject迁移本切片未实现，保持UPGRADE_REQUIRED关闭，不因保留旧密文或系统窗口取消继续PIN业务。

标记发布失败时，同一slot锁内同步退役仅本slot无auth HMAC alias，使旧false包不能在正常App重启后再被验证。若alias删除也失败，只诚实报PERSISTENCE、当前RAMclosed/owner已退役，不能宣称标记已持久或旧包已失效；要明确本地退出/清理后新身份，不重新初始化预算。对root恢复完整旧文件/Keystore状态仍不提供硬件回放保证。

## 单个认证原子包

每slot一个noBackup `HARMPN01` binary packet：版本头、严格0/1升级标记、固定scope、Go规范密文Record、完整尝试状态，再附HMAC-SHA256。字段与长度有界，最大24576B，拒尾随、负值、错hash/参数/编码及MAC篡改。单个包令record与limiter原子初始化/更新，没有“旧key文件仍在但limiter缺失当零”的入口。

MAC key用AndroidKeyStore生成无用户认证HMAC256，校验key用途、digest、大小、origin与不可直接导出。alias精确含当前UID/package/namespace/slot衍生标识；无软件MAC回退，不声称这个key是用户认证或必在硬件。包路径固定在private noBackup目录，0700/0600；拒明显symlink，AtomicFile/fd.sync/目录fsync/精确MAC重新验证readback完成后才返回成功。

slot级非阻塞实际FileChannel.tryLock加同进程AtomicBoolean覆盖Load→precharge→KDF→settle→成功Release。锁不依赖JNI回调仍位于同一JVM线程。Commit核expectedRevision及完整charge/settle形状；磁盘/释放不确定只关闭并同步retireOwner，不能发lease。Go provider/cooldown仍须跨等待按钮保留，不因每次重建反复施加完整冷却或回拨墙钟提前解锁。

MAC验证在解码前，完整scope固定，升级true进入Go load/commit也拒绝。RecordHash针对规范Go Record.Encode密文字节；非规范/自制Record仍会在Go严格复验时拒绝。软件计数/HMAC不能防低熵PIN离线猜测或root完整旧快照；HMAC alias删除也不等于对已复制软件PIN密文的可撤回加密擦除。

## 关闭、遗忘与剩余接线

任何失败/取消/保存异常/模式改变必须同步retireOwners，清旧Recovery RAM registry；PIN包不保存old recovery Ed、seed或接收私钥。正常成功单次Device/Workflow.Close可以detach独立Recovery owner，但不延长其原TTL；下次操作仍要新PIN。Go wrapper须把原ctx取消和privateowner关闭责任实际接通。

forgetLocal只做本地清理：先关闭owner/core，固定slot删除MAC alias与packet/.bak/.new，再调用同步PinLocalCleanup清真正Go保护context、device wrap key/文件、cache/journal及遗留副本。故障/已closed原provider也允许这个明确清理入口，但不能读取/解包旧钥、不新建MAC key、不删云vault。任一步失败继续closed，不报退出成功。完整cleanup接口目前未实现/实测；新PIN以后必须新Ed/X/deviceID及真实重新授权或正式恢复，不能靠账号登录找回旧identity。

## 验证入口与实测边界

`python3 tool/native-pin-host-test.py` 使用现有固定Java17/Kotlin2.4.0/Android API36缓存，仅编译三native类和两test源，然后运行主机main。没有Gradle/ADB/AAR/下载调用，不抢AVD或改系统PIN。主机只验证纯分类、同一binary codec的成熟JCA HMAC完整包/篡改/升级标记、实际跨实例与跨进程文件锁及自建子进程kill后释放；公有合成cipher fixture不是可解密Go设备材料。

`PinLocalStoreAndroidTest`五项是真正AndroidKeystore/AtomicFile/CAS与升级成功、发布失败退alias、双持久失败诚实关闭测试。本轮只编译，未运行；主机JCA测试不冒称AndroidKeystore成功。真实classifier、OS升级、forgot跨workflow清理、Go PIN wrapper、每op实际PIN及批准CLI均未跑，产品能力继续关闭。等待桥接代理提供隔离AVD窗口和成熟私有Go adapter后再单独验收。

固定错误仅BUSY/BLOCKED/UPGRADE_REQUIRED/CONFIGURATION/STATE/PERSISTENCE/AUTHENTICATION/CLOSED；不日志输出PIN、私钥、材料、intent或native packet。依据[Android BiometricManager](https://developer.android.com/reference/android/hardware/biometrics/BiometricManager)、[KeyProperties](https://developer.android.com/reference/android/security/keystore/KeyProperties)与[Android Keystore](https://developer.android.com/privacy-and-security/keystore)。

冻结候选本机结果：固定Java17/Kotlin2.4.0/API36编译三native类及两test源PASS2.956秒；主机7项全部PASS0.136秒，含真正跨进程锁和自建子进程kill释放。首次草稿编译FAIL（构造器笔误和非public O_DIRECTORY常量）已修为合法构造器及真实目录O_RDONLY+fsync，未动断言/版本。Android五项、实际PIN wrapper/产品仍UNRUN。源码基础扫描与人工范围检查PASS；只新增此切片7文件，没有旧Plugin/Gradle/GoMod/UI修改。
