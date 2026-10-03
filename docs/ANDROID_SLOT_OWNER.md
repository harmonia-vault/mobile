# Android 全 writer 槽位 owner（候选，分批有限实测）

固定源码底座为 mobile `ecbbc6212c14ca4335038a14abb66900d7217373` 与 core `6d8178ae3116e6eb9dc4c1a9197c885c6a7687b1`，仅叠加本切片列出的原生源码。它不替代此前 4469 产品续办证据，也不把新的公开 HEAD、PIN 或 DAG 算作同一产物已验。

一个逻辑槽位的系统设备包、workflow、PIN record/limiter、PIN workflow、创建 locator 与其精确 aliases 都在同一完整 snapshot 中。普通 Save、原密文 Check/CAS、创建、退出/删除、PIN charge/settle/升级 latch/forget 均持有共同 owner；认证得到的旧 writer 不可读取新的 expected 再覆盖。包内容验证与云端来源、签名和权限验证仍由成熟 Go 高层完成；锁和 snapshot 不授予云信任。

共同锁文件长期保留，不随退出/forget删除。文件必须是本 UID、0600、普通文件、单链接，path 和打开 FD 的 dev/inode 必须一致；自建目录为本 UID、0700、无 symlink。SDK `context.noBackupFilesDir` 框架 parent 使用独立校验：仅该固定路径允许本 UID/GID、真实目录、0700 或 API34 实证0771，path/FD dev/inode/完整权限必须一致；不 chmod，不将此策略用于保险库、锁或 PIN 自建目录。先取得进程内 busy 再打开 FileLock，避免另一个同进程 FD 的关闭解除已有 POSIX 锁。释放或 FD close 结果不明时保持本进程 busy。读取采用公开 `O_NOFOLLOW/O_NONBLOCK` 和打开后类型/inode核验，不因同名 FIFO 替换阻塞短提交 gate。

新 owner 接管已可见的记录前，先对验证过的固定 base/backup/new 文件 fsync 并确认 close，再同步原目录、永久锁和目录路径；之后重新核对同一完整包，才能捕获为本次持久基点。这样可处理此前 rename 已成功而目录 sync 未确认的记录；它不把未验证密文视为可信。仅 `.new` 而无正式包/备份的 workflow 仍拒绝读取。

所有 AtomicFile 写入在调用 finishWrite 之前标记 publishing。发布前失败才允许 failWrite；finishWrite 自身、目录 sync 或 readback 失败都可能已经提交，必须保留可见记录并退役 owner，报告结果不明。不会保证这类失败恢复旧密文，也不会清除未知提交。后续明确操作只可由新的真实认证 owner 验证现有材料。

设备创建使用受本机 HMAC 认证的持久 intent，详见 [创建边界](ANDROID_DEVICE_SETUP.md)。取消只消费本次精确 prepared 创建意图；进程在 prepared 后死亡，下次明确 create 可清理该 intent 所指的唯一 generation alias 后重建。ready locator 持续保留以定位包封 key。设备已保存但 locator 未 ready 时须正常强认证解包及 Go 验证后补全，不能推断失败并删除设备。

`OpenAtomicWorkflow` 的静态参数保留 gomobile 外部 Check/CAS 方法；旧 `OpenWorkflow` 保持兼容。本机 `Invalidate` 只立即撤销后续 lease 并取消 context；必须在 native 保存 gate 外调用，worker 排空后再 Clear/Close 清钥。每操作 `operationEpoch` 与未来跨认证的宿主生命周期 generation 分开；本片尚未接 B1 的稳定 PlatformEpoch，也未开放 DAG、PIN DAG、新 Recovery ABI 或 Flutter 能力。

## 有限验证范围

Go 定向 race 覆盖 typed opener 两次检查、CAS，以及 Invalidate 不等待关闭 barrier/取消后 lease 不可复用/最终关闭一次。Kotlin host 原8项及新增框架 parent 拒绝边界覆盖普通 writer 冲突、取消不可复活、清理单次、发布结果不明、短 commit 排空、仅 unchanged 失败消费清理票及释放异常保 busy。Android SDK36 源码和 arm64 AAR 已编译；运行目标是 API34，编译版本不代表运行版本。

修正后的 Android 六项已执行；以下是固定范围，各项实际结果见后文：

1. 真实 Go→JNI Check/CAS，随后普通 Save；旧包 CAS 失败永久关闭 writer。
2. 真实 typed opener 通过 Java Atomic 接口执行 Go Logout→密封 Save，关闭后的旧 writer 拒绝。
3. 同 UID 跨进程 FileLock、取消后排空、永久锁保留；合并 `.new` 残留与不安全锁权限拒绝。
4. 完整包变更拒绝旧 Save/删除；finish 后 sync 故障保留新包，旧 owner 关闭，新 owner 同步捕获后才可继续。
5. PIN store 的 HMAC record、charge、workflow、settle、forget 共用 owner；仅 storage，不声称真实 PIN 解锁/KDF 已验。
6. 真实系统认证创建取消→无材料；同 UID 子进程 prepared 后真实死亡→明确新 create→新 CryptoObject，公钥仍 untrusted；按精确 locator 清理。

`tool/native-slot-owner-test.py build` 只构建。`run` 还要求已审 manifest SHA、固定 emulator-5580 和本人 emulator PID；SDK 确认无系统凭证后才生成本次 RAM 合成 PIN，官方 locksettings 准备，真实一次取消和一次 CryptoObject 成功，finally 同 PIN clear 后实际 SDK 确认无凭证。仅安装/卸载两个专用包，不重跑 4469、Flutter、云端 CRUD 或 CLI。秘密不进入日志、截图、JUnit 参数或输出；合成 PIN 仅正常官方测试命令的 RAM argv。凭证或 worker 清理不明保留 RAM owner 并报告阻塞，不猜成功。

## 第一轮实际定位与后续候选

第一轮六项实际6/6 FAIL（JUnit1.472秒），统一在同步目录前置停止，未完成目标JNI/CAS或创建重开。官方合成系统凭证clear及SDK无凭证、两个专用包卸载、原包集合保持均PASS；host一次双Back仅是取消输入动作，不作为实际取消callback通过。原freeze和FAIL原始证据保留。

随后独立metadata-only探针实际1/1 PASS0.308秒：SDK noBackup parent mode0771、UID/GID本UID、目录类型、path/FD dev/inode/uid/gid/mode一致、FD open/close确认，SDK无系统凭证；两探针包已清，未改mode/读内容/设置PIN。由此新增上述固定framework parent helper，其他自建private目录仍0700。新host边界拒绝wrong UID/GID/mode/type、inode/device替换及核验间模式变化。修正后 APK-v5 六项实际4 PASS、2 FAIL（JUnit5.060秒）；结果和清理见下一节。

## APK-v5实际与JNI空状态修正

本轮4项PASS：完整包变化/提交不明后新owner捕获、取消排空/同UID跨进程锁、真实创建取消及prepared子进程死亡后重新创建、PIN存储同owner至forget。创建场景实际确认取消callback和新CryptoObject成功，仍无云信任；host动作1次取消、1次凭证输入。官方clear退出0、SDK最终无凭证、两个专用包清理及原包集一致均PASS。

2项FAIL是实际Go→JNI首次空密文边界：gomobile将空Go `[]byte`传为Java `null`，Kotlin非空callback在比较前抛NPE；因此真实Check/CAS和typed opener尚未通过。本轮源码与已审24源无变化，第一轮6FAIL和metadata PASS均保留，不合并为六项通过。

后续窄修仅允许外部expected可空并按空bytes严格比较captured；它不能传入普通Save/delete内部省略caller比较的sentinel。next为null拒绝，owner及完整包核验不变。Plugin与测试代理同样接收可空JNI签名。host新增null/空expected对非空capture拒绝、非空expected对空capture拒绝、换字节拒绝及null next拒绝。Go和两AAR不变。

修正后的定向runner `tool/native-slot-atomic-jni-run.py`固定只选原两项JNI方法，使用[官方AndroidJUnitRunner单方法选择](https://developer.android.com/reference/androidx/test/runner/AndroidJUnitRunner)，不重复四项已过场景、不设置系统PIN。它核已审manifest、APK/源码、固定本人AVD身份、SDK无凭证前后置和精确两包清理；实际运行仍须新diff/APKmanifest审阅。APK-v6这两项修正后各1/1 PASS，JUnit各0.040秒、host整段0.937秒；SDK前后无凭据、精确两个包清理、原包集合一致均PASS，没有cleanupBlocker。该轮没有PIN/认证输入，不开放DAG/B1/UI能力。

## 最终分批证据（2026-10-03 UTC）

| 产物 | 实际范围 | 结果 |
| --- | --- | --- |
| APK-v4 | 原六项 | 6 FAIL，JUnit1.472秒；框架parent0771被原0700前置拒绝 |
| metadata probe | 独立只读目录元数据 | 1 PASS，JUnit0.308秒；未改mode或设置PIN |
| APK-v5 | parent窄修后的六项 | 4 PASS / 2 FAIL，JUnit5.060秒；两项JNI空状态NPE |
| APK-v6 | nullable窄修后的两项JNI | 各1 PASS，JUnit各0.040秒；未重复其余四项 |

这些是不同精确产物的分批结果，不能写作“APK-v6六项全过”。v5真实创建取消、子进程死亡后重开、系统CryptoObject和PIN存储仅在上述限定范围通过；v6只补真实Go→JNI Check/CAS和typed opener→Go Logout密封Save。完整Flutter产品链、B1跨认证PlatformEpoch、DAG高层/ABI/PIN DAG均不属于本轮。

[脱敏证据JSON](evidence/android-slot-owner-20261003.json)保存固定底座、源码/产物哈希、各轮实际与清理；原始日志和二进制只在私有ignored缓存，不公开宿主路径、PID或秘密。最终发布候选仅文档相对已编译26源更新，未重建APK/Go/AAR。
