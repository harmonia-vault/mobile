# 环境 CRUD 手机非视觉接线候选验收

基于 mobile `5887c739f085eebe73e5035b974fe54676e24b96`；冻结12个源码、测试与说明文件。未修改live工作树、工具链或既有运行候选。业务源码与第一次10文件非视觉冻结逐字一致；只增加根任务已审Claude选择组件、机械接线及对应文档。

## 实际结果

- PASS：最后相关非视觉业务测试65项，8.190秒（`affected-business-final`）；涵盖本片环境路由、恢复业务与闭环、恢复pending、生命周期及gateway。无widget测试。
- PASS：环境定向11项，1.980秒（`dart-test-02`）。变量域既有13项在首轮均PASS。
- PASS：完整Dart静态分析，2.813秒，无issues（`dart-analyze-02`）。
- PASS：Kotlin请求封装以JDK17编译2.541秒；纯JVM16项，0.074秒（`channel-host-01`）。没有加载或伪造Go ABI。
- MATCH：环境dispatcher按明确类型/方法/字节字段/固定错误/注释名称归一后，与基线变量dispatcher控制流全文相同（`DISPATCHER-REUSE.json`）。仅源码复用证据，不是SDK编译证据。
- MATCH：Go最终合同及引用源码hash（`GO-CONTRACT-REFERENCE.json`）。Go环境六op最终manifest `a7ac54662ed32a05083d0e47c3380bb3b402d75b0c2e17970812edefb340c1ba`；调用合同 `18c181c619b41fd06c2139a0c96496615e55d1458cfaaa0cfd1cf3fa116127fe`。本片没有重跑Go集成或声称其结果是Android结果。

- PASS：Claude控件机械接线后完整Dart静态分析，7.210秒，无issues（`authority-ui-analyze-final`）。业务源码未改，按授权不重跑已PASS业务/JVM。

## 保留的失败

- FAIL：首次离线pub get因沙盒拒绝SDK缓存engine.stamp写入；经授权相同离线操作PASS。未更改产品代码，未用真实凭据。
- FAIL：`dart-test-01`，5.164秒，22 PASS／2 FAIL。两个新测试用含Map的record作整体相等比较，实际字段相同但Map按身份不相等；拆分操作/字段断言后环境11项PASS。该历史不改写。
- FAIL：`dart-analyze-01`，3.540秒，10个缺少大括号的info；补大括号后静态分析PASS。该历史不改写。

## 未跑与合并边界

UNRUN：新Go AAR绑定、真实Android SDK全编译、JNI、系统CryptoObject实际认证、AVD、Flutter点击链。Claude选择控件已有源码及机械接线，未做实际UI运行。默认verified环境能力仍为空，全局ready不开放；此候选不宣称P1实际整链或生产可用。

新建表单已接入根任务使用用户指定Claude生成的明确Admin authority选择；provenance仅保存模型、单次耗时、原始/格式化hash及机械修改说明，无本机路径或原始上下文。现有环境详情尚无轮换按钮，控制器方法已提供。控制器API与表单定位见 `mobile/docs/DAG_ENVIRONMENT_MOBILE.md`。根统一合并时应用冻结12文件，并将其余并行增量按同一源版本构建；不得只因编译声明存在而开放verified能力。
