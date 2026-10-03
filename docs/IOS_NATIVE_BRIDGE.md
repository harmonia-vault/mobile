# iOS 原生安全桥候选

这是实验性候选，不能宣传生产可用。共享 Flutter 页面、控制器、Android、Go 业务与协议均未修改。`realVaultReady` 始终为 false；登录成功与本机公钥都不能授予设备信任。

## 固定边界

- mobile 基线 `a06acaf9944e71523e5116404111993483be93d7`；core-go 基线 `b094a933bf1922347b4a41ea8baaa5699ffbf5c1`。
- Go `1.26.4`；gomobile/gobind `v0.0.0-20260908204917-8b95e45f8d3e`；BoringSSL `fab96f87245d7c6b941515201843665122650b88`；Flutter `3.47.6`。
- `tool/native-ios-build.sh` 只接受已核验的固定源码和工具，交叉构建 iOS arm64 与 Simulator arm64。不能执行内部会安装 `gobind@latest` 的 `gomobile init`。
- Go c-archive 不自动包含外部 `libcrypto.a`，脚本明确合并对应 iOS BoringSSL 静态库，再生成双 slice XCFramework。产物位于 ignored `build/`，不提交 framework、app 或安装包。

## 系统认证与设备钥匙

`SystemAuthentication` 实际调用 `LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)`。只有该完整策略的 `LAError.passcodeNotSet` 被分类为无系统认证；用户取消、系统取消、认证失败、锁定、未录入生物识别、暂不可用及未知错误均不能提供 PIN 资格。设备密码即可使用，不要求 Face ID、Passkey 或 Apple 开发者计划。

每个业务意图使用新的 `LAContext`，关闭生物认证复用时长。钥匙读取直接执行受 `userPresence` 与 `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` 限制的 `SecItemCopyMatching`。创建先系统认证，再 Keychain 存储和真实读回；不拿一个认证成功布尔值代替受 ACL 保护的取钥。存储查询固定本 app service/account，禁止同步，不枚举其它 Keychain 项。

Swift 只在当次原生操作导入 Go 软件 Ed25519/X25519 材料，操作结束关闭 Device/Workflow、使认证 context 失效，并清理可控字节。Go、Swift Data、Objective-C bridge 和运行时可能复制内存，不保证全部副本硬擦；软件设备钥匙不宣称始终位于硬件内。

## 原生业务与保存

沿用 `org.harmoniavault/native/v1` 的有限方法：capabilities、executePublic、createDevice、executeUnlocked、workflowProfile、executeWorkflow、executeApproval、executeEnrollment。短码单独传字节；没有任意签名、raw key、trust bool、CA、保存回调或恢复 owner 的通道注入接口。

每个完整命令被固定捕获；Go 继续严格解析所有字段、端点与原 ID。单个原生业务 gate 避免并发覆盖。命令等待认证或执行期间进入后台会使 epoch 失效，取消当前 LA/Go workflow 并清理恢复 owner；晚到结果只能报告 LOCKED。

`ProtectedWorkflowStore` 只接收 Go 的 HARMST01 密封状态，固定 app namespace/文件。保存依次执行私有权限、备份排除、Complete 文件保护、临时文件写入、fsync、原子 rename、目录 fsync、精确读回。任何一步失败都不确认保存成功。线上写入的持久 pending、原 ID 续办、samePull 和信任校验仍由成熟 Go 业务执行，没有新增旁路。

SceneDelegate 在失去前台时遮挡内容；真正进入后台使原生业务失效。返回前台如有受保护钥匙，必须再次从 Keychain 真实认证取回后才去掉原生遮罩。临时系统认证界面造成的 inactive 不等于后台，不会自己取消认证。遮罩失败可轻点重试，不显示秘密。

## 私有 PIN 候选

`LocalPINSlot` 当前未接产品通道或 Dart，`appPinReady=false`。它复用同一成熟 Go LocalPINCore 的 Argon2id 64 MiB/3/p1、AEAD、意图绑定和一次性 lease，Swift 不重写原语。

资格来自实际 LA 检查，同时必须无旧系统 Keychain 项与系统密封状态。PIN 的原始 Record 字节不经 JSON 重排。record、公开 scope、尝试元数据和 workflow 密文一起由独立 Keychain 软件 HMAC 钥认证，原子保存、fsync、读回；完整业务与 KDF 尝试各有跨实例/进程 flock，保存校验原文件摘要与尝试 revision CAS。丢失、篡改或部分失败不重置尝试次数。系统后来 ready 会先持久写 upgradeRequired；迁移未实现，之后拒绝 PIN 业务。

创建时如生成 MAC 钥后保存失败，会幂等清理本次空 slot；清理失败明确留下 incomplete，禁止自动覆盖，必须显式忘记。Go Close、尝试锁释放和完整业务锁释放/关闭失败都会覆盖原操作成功，不能吞掉清理错误。忘记会同时读回核验 packet 与精确 Keychain 项均不存在。

忘记 PIN 只精确清理该 slot 的本地 packet/Keychain 项与 RAM owner，不解包旧钥匙、不发云端删除。重新 setup 必有新 Go 随机设备/gen/epoch，仍需真实可信登记。普通 workflow 候选已接；PIN 的审批、入网、产品生命周期绑定及恢复尚未开放。PIN 正确不能赋予设备信任。

低熵 PIN 仍有离线猜测风险；软件 HMAC、文件保护与 flock 不能抵抗 root 完整磁盘快照回放。任何 Simulator 结果均不能证明真机生物识别、Secure Enclave 或硬件防回滚。

## 参考

- [Apple deviceOwnerAuthentication](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication)
- [Apple Keychain userPresence](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence)
- [Apple WhenPasscodeSetThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenpasscodesetthisdeviceonly)
