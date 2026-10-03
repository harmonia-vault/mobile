# Android 产品正式退出最小实际回归（2026-10-03 UTC）

本轮独立回归 **PASS，53.267 秒，9 次真实系统 CryptoObject 认证窗口**。实际 Flutter 产品页面完成注册、邮件证明、首机完整恢复码重输与 Boot/Pull；观察到前台稳定后，从 C 设置页执行正式退出。退出后登录页出现，设备材料、workflow 状态及包封 alias 均不存在。系统仍有本轮合成屏幕锁时，本地 `prepareOpen` 因无材料被拒绝；正常 Activity 重启回到连接页，材料仍不存在。

生产来源是公开 mobile `ac1e872ce138ee8000837a24141ad8900200c8c7` 加已公开 `8a0515c374dea6bd29e966e442c804b2222db7a7` 的精确三文件生命周期修复，生产 source manifest 为 `18a603cdb47b89cfbb80359bdf9aacb8c96a7f1cd592a8d65804d2705f19f93b`。没有新增生产变动或重新构建 Go。AAR 来自公开 core `b094a933bf1922347b4a41ea8baaa5699ffbf5c1`，SHA-256 为 `fb9664f6ccc13707367a12e64f28663fc17018ff4d8bb044ea37d913be2e1d0b`。服务来自公开 server `bd86fec6215b6f7149234578e7bf5dc764a639c2` 与先前审阅的有限 test-only HTTPS helper，使用新空库和新临时 CA，标准链与主机名验证通过。

新 app APK 为 `cde512caff3404ad9065dd674227c106b8de0a72c17a241dac04b87feea4cc5a`，test APK 为 `bf088f2010d21ed6676526ebf376a4336da87e4ad30314b41f14554aeb5dc758`。产品构建 3.156 秒、测试包构建 1.139 秒，均通过。测试驱动只新增可观察 SDK idle、材料存在布尔及正常 Activity 重启；正式业务仍由实际触摸、逐键输入和系统认证驱动。

本次 accepted 计数是注册 1、邮件证明 1、JIT 登录 1、初始化 1、初始化后的环境改名 1、Boot 2、Pull 5。变量 mutation 与 V3 approval 都为 0；CRUD、CLI 批准不在本轮重复。完整的源码、产物、阶段和计数见[公开证据](../evidence/android-product-logout-20261003.json)。

finally 官方清除仅本次合成屏幕锁，独立 SDK 确认设备回到 noSecure。仅本次两个专用包、转发及 4463 服务已清理。原预览包 SHA-256 保持 `4d3efb2d745734664a28f1725855eb73da8b963f5bfea2884668de0a88611c66`；保留原 AVD 和正常缓存 AAR `7af225529d2d5cea6c435e28f568e7d3a3cd523688ed8a966be16dd1dfed1e08`。

本轮不确定此前 4461 最终退出失败的原因。此前完整流程 **149.966 秒、34 次认证、whole FAIL** 原样保留；其已通过的真实 App CRUD、默认版本 3 CLI 批准、daemon 读取与 CLI 写回 App 阶段仍按[原阶段记录](ANDROID_PRODUCT_USERFLOW_20261003.md)报告。SDK idle 不是认证证明；本地 open 抛异常也不归因为某个特定错误。没有放宽认证、来源验签或权限门槛，整体 `realVaultReady` 仍为 false。
