# Android DAG 变量业务同来源编译记录（2026-10-04）

本次完成已恢复 DAG 来源变量写删及原请求续办的宿主编译集成。normal arm64 AAR、实际 generated Java ABI 与 API36 全 native/MainActivity 编译通过；JNI 实际调用、系统认证和真实 Flutter 产品操作尚未执行，不能据此认定 P1 完成。完整结果见[脱敏 JSON](../evidence/android-dag-variable-compile-20261004.json)。

## 精确来源

- Go：公开 core `28a35f286e9ff4bafabf62c0daedca84e0530de3` 加已审 v2 15文件 overlay，manifest SHA `1ff27b2a04ddb202c1d5a7ed3b1b767fd504d5f00a4759df20546611f745bc64`。同批另一个 workspace 验收源只作证据参考，没有加入 AAR 编译输入。
- Android：公开 mobile `951e09d286bcb744e0c7471cfb4acc7823b13876` 加 f188 五文件，含三个主生产源、一个已有 host 测试及一个说明文档。
- Dart：f40f 七源只作为后续产品接线参考，不是 Go AAR 或 API36 Kotlin 的编译输入；合成受影响业务测试76项通过、analyze3.1秒无问题。这些不是本次原生运行证据。

不能把以上产物冒称为当前最新整棵仓库验证。旧 v1 冻结、历史测试结果和缺文档镜像的前置失败均保留。该前置失败发生在 Go overlay和构建之前，只补入批准的相同 SHA 文档后继续，没有修改安全源码。

## 实际结果

- 一次 offline normal gomobile bind：PASS 27.946秒。AAR SHA `0d0dfd2b4b4f1b3d643164ece2d73e8b6dbf217e9f5c498711f202fade6f8998`，classes.jar SHA `1e9a0e304dda1a547dd5658c313289e1f6349c8bf80dcd4ed06bffff8ccf8480`。源码 snapshot 共675项（Go569项、固定 BoringSSL106项），构建前后全部未变；snapshot 包含测试和文档，不表示它们全部被编译。
- 实际 javap 三签名通过：`dagBusinessProfile()`、`validateDAGBusinessCommand(String)` 与 `VaultWorkflow.executeDAGBusiness(String, byte[])`。
- 新 classes.jar 对应 API36 全 native/MainActivity：PASS 16.426秒，33个编译源项，编译日志为空；其中一个 BuildConfig 仅用于复现 Gradle 生成类型，不能当作真实 App/flavor 运行。既有14项 host 证据没有重复执行。

原生入口独立于 ordinary writer 和恢复操作名单；变量值采用独立字节缓冲，原请求只能按原 ID 续办。Go 与 Dart 均明确单项成熟 Writer 的 accepted=0 序列为 `["0"]`，accepted=1为单条非零十进制。未知结果和响应格式失败关闭旧显示，须权威查询原状态后续办，不能换 ID。

compiled声明与逐项 verified 证据分开，verified默认仍空，没有因本次编译开放新能力。环境CRUD/轮换、每环境RO/RW/Admin与期限及撤销、DAG管理者和CLI授权仍须后续成熟高层和产品验证；变量片不完成P1。本片没有改live源码/共享AAR，没有操作AVD、ADB或宿主GUI。
