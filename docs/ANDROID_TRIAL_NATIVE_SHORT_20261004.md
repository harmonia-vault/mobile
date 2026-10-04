# Android 独立试用：最短原生登录与退出

2026-10-04 UTC。实验性软件；这是普通未受信账号的一条实际界面流程，不是整个 M2 或安装包生产验收。只使用既有独立任务 AVD、运行时合成账号/PIN 和局部测试 CA；旧 AVD、真实账号、系统代理与安全策略未改。

## 固定范围与修正

以 mobile `01840af1f3ac3fa90c78c7a89222ad9b6993def4` 的试用分支为基础。独立构建的包名已是 `org.harmoniavault.harmonia_trial.productfixture`，而测试 CA 的精确包名 gate 仍是旧 mobile 名称，导致原 Activity 在驱动 socket 建立前拒绝。现在只让该 gate 与真实独立 debug 包一致，不允许任意后缀、不改变普通构建的 CA 行为；增加旧 fixture 包名仍拒绝的边界案例。

本次私有执行快照比较 86 个受跟踪产品文件，差别为该常量及 Gradle 只选已有三份 Android 实际界面驱动的 androidTest sourceSet。其余比较的 Dart、Android 主程序、依赖锁定文件相同；没有改产品 UI、认证或业务机制。实际测试 source freeze SHA256：`941e0eb16800e6c1112e69e63e6d698988a898dd83c3308e582d6f70d6e12d2e`。

复用 core `2aa0c48fbe2fdbfa5348e37d02c8ff69733a6b98` 的 AAR，SHA256 `562e1e7ffc9215f623420d05abb8b3d922bef3f80e4f80002ced66bdcc734f46`；没有重编 Go/JNI。此前 Flutter 误把 platform-tools 目录当 SDK；本次仅给构建子进程指定已经安装的 SDK，正确 NDK 和既有许可证被使用，没有修改全局配置或接受新条款。

## 实际结果

- 精确测试包名与 CA 边界宿主验证：**PASS**，固定 Kotlin 2.4 / Java 17 编译 18.431 秒，16 个边界案例运行 0.589 秒；它本身不作为 Android 认证证明。

- 首次应用/测试包构建：**PASS**，174.540/14.260 秒；解决原 SDK 选择阻塞。
- 第一次最短流程：**FAIL**，302.393 秒，连接页 `SELECTOR_UNAVAILABLE`，凭据输入 0。PIN 清除、系统无凭据回读、worker 排空、包与服务器清理均 **PASS**，原失败保留。
- 使用相同 APK 复查时，实际观察到 System UI 无响应对话框遮挡连接页。正常选择 Wait 后恢复；原失败没有现场截图，不能把这一后续观察当成对原失败原因的完整证明。
- 同一原选择器独立验证：**PASS**，16.782 秒，凭据输入 0；没有放宽窗口或唯一节点检查。
- 同一 AVD 的必要续验：**PASS**，206.771 秒。新 TLS 夹具需更新局部 CA，应用/测试包增量构建 30.786/8.950 秒。真实界面完成连接、普通未受信账号登录、三次系统认证（create/login/logout）和正式退出；退出后真实受保护 device/workflow 材料不存在。
- 三次输入均核对固定 System UI UID、唯一焦点窗口、KeyguardDialog、BiometricPrompt 标题和输入前焦点稳定。顺序读取不是原子 OS 快照，保留这一限制。
- 最终清理：**PASS**。官方 clear 成功；独立 SDK 回读无系统凭据；合成凭据 intent 删除；测试包与服务器清理；精确任务 AVD 正常停止，磁盘保留。

成功实际 APK SHA256：`98bfedacd5dbe51cfdd5a941a3a107ccda094f46fe788c8a04cc08030fb635cf`；测试 APK SHA256：`bec7afdeac4e7820d8f4c91f9d391de1feda525f7d9439b56fc371db435a5661`。它们是带局部 CA 的独立测试变体，只保留本机，没有发布。此前交付的普通 debug APK 哈希没有改变，不能声称本次运行了那份 APK 的完全相同字节。

账号登录后保持等待授权，未创建可信设备授权；夹具初始化已有的 Boot/Pull 计数前后不变，不能把管理夹具流量认作该手机可信设备的 Boot/Pull。本次没有验证恢复向导、授权管理、重置、完整 CRUD、跨账号切换或整个最终快照，相关能力门槛保持原状态。
