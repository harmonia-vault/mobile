# Android DAG 生命周期 A 分片（2026-10-03 UTC）

这是实验性源码/编译组件，不是已开放的手机恢复能力。固定公开 mobile `85f8c6c116d7a0efcf7d8321c8c6caf63fabafcf`，Go `67db4a7999d7827a7418d6ad4094ddd73d64145a` 加明确 bridge生命周期overlay；未混入未发布B3a。没有 Flutter/UI/server/协议改动，没有ADB/GUI、安装、PIN、服务启动或产品4469重跑。正常/live AAR未覆盖。

`NativeSlotLifecycle` 在同一个宿主/slot保存稳定正 PlatformEpoch。正常认证完成和下一次新票不改变它；注销、取消、失败、后台/ScreenOff、失效、销毁才退休。每张票含私有serial/CryptoObject身份，以及未来dispatcher必须从真实SlotSnapshotLease捕获的operationEpoch；serial本身不冒充文件owner epoch，PlatformEpoch更不能用该每操作epoch替代。Epoch溢出永久关闭，不接受Dart值。

MainActivity仅增加真实SDK onResume/onPause/onStop/onUserLeaveHint/onDestroy 和动态ScreenOff hooks，设备锁定来自KeyguardManager。A尚未把生产BiometricPrompt/业务接到新票，也没有创建DAGregistry或新MethodChannel。现有普通认证操作不因这套未接通的票改变行为。后续B必须在真实authenticate旁建立精确ticket并在成功回调消费，不能凭合成状态机测试或Dart前台bool开放能力。

正常prompt短暂pause无业务permit。系统密码使宿主stop时，只有已经实际开始的本次原生AUTH_WAIT票才进入最长30秒AUTH_WAIT_STOPPED；不授lease、不发HTTP、不Check/CAS/Save、不返回数据。此状态承认公开SDK不能完美区分所有覆盖原因，不以package白名单推断。真正HOME/ScreenOff/取消/失败/超时/销毁使原generation永久死票，迟到callback不复活；旧callback也不能把另一个新ticket错误退休。

成功回调必须与原CryptoObject相同并consume-once；未前台时最多5秒等待真实SDK resumed。resume和callback两种先后顺序均支持；单独resume不认证。5秒只约束等待前台，不误作已消费业务的寿命；一次业务最多30秒且不超过原认证票120秒上限。Go owner及服务器期限仍各自独立，绝不续。所有timer取消、retirement回调在短native gate外执行；立即回调仅取消/失效，清钥/drain排到worker。

系统设备密码与BIOMETRIC_STRONG都必须支持；目前真实密码/生命周期事件仍UNRUN，不能把未测窗口问题永久变成只允许生物认证。B需验证标准credential期间stop和正确输入/resume、HOME/取消/超时与迟到callback，未知行为保守关闭并报告。

有限host10项覆盖两个正常新票、两种stop/resume/callback次序、HOME/ScreenOff/cancel/dispose、30秒parking/5秒前台预算、未开始SDK及ACTIVE后台、精确CryptoObject/一次callback、迟到旧票、callback不持native gate及epoch溢出/锁定。没有UIKit/Flutter界面测试，也不能称这些纯事件为真实系统成功认证。

编译验证使用固定Kotlin2.4.0、Java17、API36 Android SDK、Flutter3.47.6 embedding及其官方POM声明的LifecycleOwner依赖。真实gomobile生成Java类型被Kotlin签名探针编译引用，包含newNativeDAGRegistry/attachDAGRegistry/invalidate/close；编译不是JNI执行。首次runner缺少LifecycleOwner classpath的失败保留；补官方缓存依赖后通过。不下载/安装新的工具。

候选验证入口 `mise run test-native-dag-lifecycle` 必须显式传独立candidate、固定AAR及新输出目录；Go的 `mise run test-native-dag-registry` 为定向race。完整manifest记录固定源码、BoringSSL/工具输入、AAR及原始结果SHA。当前没有开启DAG/S2a/B2/PIN DAG/B3能力，整体ready保持false。
