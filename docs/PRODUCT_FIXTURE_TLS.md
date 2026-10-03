# 独立 debug 产品测试 TLS 配置

2026-10-03 UTC。本页只记录固定公共CA配置与源码构建边界，不声明Android MethodChannel/认证前拒绝、TLS网络或Flutter产品用户链已运行。四意图actual3/3证据在[ACCOUNT_NATIVE.md](../../core-go/mobilebridge/ACCOUNT_NATIVE.md)，本配置不夹入其产物；整体ready=false。

## 固定合同

只有显式Gradle `harmoniaProductFixture=true` 的独立debug包 `org.harmoniavault.harmonia_mobile.productfixture` 可开放零参数 `fixtureConnectionInfo`，返回严格 `{version:1,productFixture:true,endpoint,caPem}`。没有token/设备权限或账号信任。普通构建该方法返回notImplemented、无fixture capability、编译字段false且endpoint/CA为空；本机公共CA配置文件即使存在也不被普通分支读取。

公共配置固定在ignored `mobile/build/native/product-fixture.json`，严格两个字段 `{endpoint,caPem}`，不接受调用方CA、任意路径、私钥、远程地址或URL参数。endpoint只允许canonical无路径loopback HTTPS origin（127.0.0.1/localhost/10.0.2.2/::1、合法端口）；CA须单个有效自签CA证书。MainActivity以编译布尔与实际包名构造私有ProductFixtureConfiguration，错误包名/release/配置拒绝；没有运行时setup入口。

executeWorkflow、executeApproval和executeEnrollment必须与编译endpoint字符串精确相等，在系统认证前拒错误地址；拒绝审批/入网时清收到的shortCode缓冲。Go沿成熟标准HTTPS并保留系统根，追加公共CA，chain/hostname校验和不跟随redirect保持。无SkipVerify、全局HttpOverrides、badCertificateCallback或调用方CA。Dart局部SecurityContext由独立UI业务slice负责，必须只用于该fixedendpoint；此原生切片没有修改Dart UI或gateway。

Debug是独立调试构建模式，不是可发布flavor。显式release/profile/全assemble/build请求及间接release/profile任务图均拒绝；productfixture与nativefixture互斥。普通/release的默认BuildConfig关闭测试字段。BuildConfig与任务图检查依据[Android BuildConfig参考](https://developer.android.google.cn/agents/skills/build-system/agp/agp-9-upgrade/references/buildconfig)和[Gradle TaskExecutionGraph官方API](https://docs.gradle.org/current/javadoc/org/gradle/api/execution/TaskExecutionGraph.html)。

## 固定源码及构建结果

最终ignored快照为 `core-go/.build/native-productfixture-final-snapshot`，公开mobile `f108a5519ba08ffd797621d4eac6e8b9ebfb0c20` 加source-manifest明列6候选（Gradle、MainActivity、NativeBridgePlugin、新ProductFixtureConfiguration、host test、host runner）。复用四意图已实际通过的正常AAR，没有新Go构建或业务通过声明。source-manifest SHA256 `2bef30ed5bea64d1703af188160be834c4684dc8fe5e0afb3bff5cdb0756dab6`，构建/检查后 `archivedSourceChanges=[]`。公开UI底座与当前UI草稿分开，不声称HEAD/整个当前树或产物字节完全可复现。

| 产物 | SHA256 |
| --- | --- |
| `build/native/harmonia-go.aar` | `7af225529d2d5cea6c435e28f568e7d3a3cd523688ed8a966be16dd1dfed1e08` |
| `build/native/productfixture-debug.apk` | `79fb8cc31953ea069acd787fd2bbacef6c3ff4ee9f3e6e7ffe1d259f3c935222` |
| `build/native/default-debug.apk` | `590c1535055ce9b85f09dbf1d47b1296e84872965dc3ecd002c6afe5c247ccc6` |
| `build/native/product-fixture.json` | `5c1e20c3cbd0a54295eaca70ad6903707194dc15e7a90d782c301c522eb669b9` |

公共CA SHA256 `99058b7cc95a9e75aa98d7e785c505a14e19f832fe75302cb290491d52d8411d`；固定地址 `https://10.0.2.2:4443`。此CA只用于配置验证，原fixture进程和CA私钥已清；下一真实产品服务须生成新的临时公共CA并重新构建绑定APK，不能用旧证据假称正在联网。

固定Kotlin2.4/Java17 host编译2.099秒、运行0.085秒通过：固定配置正例、默认无能力、14负例（release、错误包、remote/http/path/query/fragment/端口、缺CA、双证书、合成私钥header等）。没有私钥body；该header仅固定片段组成同运行时负例。真正productfixture debug APK构建10.2秒、默认APK构建3.2秒通过；aapt2实际包名分别.productfixture与原普通包。默认生成BuildConfig实际false/空endpoint/空CA。

六项真实Gradle构建拒绝均通过：release、全assemble、冲突fixture、缺配置、远程endpoint、空CA，均非零exit且精确固定错误类别，不把偶然编译失败算门槛通过，没有生成releaseAPK。首source b8b8ff49曾因DSL的java名称遮蔽导致编译FAIL；显式Files import修正后ecec4d71构建PASS11.2秒，最终仅调整合成header源码表达避免基础scanner误报，重新host和APK构建后才记录本页。日志与manifest都保留ignored；一次host误传配置JSON不计正例，之后使用真实公共证书重跑通过。

## 复现及下一实际链

在独立源码快照准备已测正常AAR、显式固定SDK/Flutter local.properties与locked离线依赖。写上述公共配置（不存私钥），运行 `PYTHONDONTWRITEBYTECODE=1 mise exec java@temurin-17.0.16+8 -- python3 tool/native-productfixture-host-test.py --public-ca <公共CA文件>`；调试构建以 `ORG_GRADLE_PROJECT_harmoniaProductFixture=true mise exec flutter@3.47.6 java@temurin-17.0.16+8 -- flutter build apk --debug`。正式产品UI还须在独立获准slice明确Dart `HARMONIA_PRODUCT_FIXTURE=true` 和单操作experimental opt-in，本文APK只是公开UI底座的原生配置构建，不把未接线用户链记PASS。

本轮没有ADB/install/系统PIN/测试账户/HTTP服务动作，AVD继续由父任务排程，原preview保留。下一合成产品链需公开真实instance-info/register源码、全新无seed实例和临时合法CA，明确用户邮件proof/初始化完整重输/可信restore/CRUD/批准CLI；之后仅清本次.productfixture包与本地账户/钥/服务。无真实手机/强生物成功、App PIN provider或cold-restore审批来源能力证据。
