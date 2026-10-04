# Android＋Linux 本地试用（仅测试密钥）

这是实验性调试构建，不是生产可用版。只输入自行创建的合成账号、密码和变量；不要导入真实系统环境或生产凭据。

固定基线：workspace `a843c8cc1621049120e25f6f948200a39e8b2762`、mobile `d94e39cc7e856c2f968cee9d2caa05a16cfbf3ce`、core-go `2aa0c48fbe2fdbfa5348e37d02c8ff69733a6b98`、server `36ab16fbaadacd766548e201c05acd5e80ccb89b`。本试用分支只修保护状态查询及异常清理线程，另用独立包名和新生成的测试签名。

## 安装与连接

交付文件为 `Harmonia-trial-debug.apk`，Android 11/API30 及以上，arm64。包名 `org.harmoniavault.harmonia_trial`，与原应用分离。APK SHA256：`0461c0dfeb1d0c2533ea7feb2869d565df3ba360eb1200ec4ad26624fbef8266`。本地固定AAR SHA256：`562e1e7ffc9215f623420d05abb8b3d922bef3f80e4f80002ced66bdcc734f46`。

先选择明确的测试设备，再安装，不自动覆盖其他包：

```sh
adb -s '<测试设备序号>' install Harmonia-trial-debug.apk
```

在 App 填写你控制的测试实例 HTTPS 地址。该交付 APK 使用系统信任的证书，没有植入验收用临时 CA，不允许明文 HTTP 或忽略证书错误。本次没有部署公网实例；本地验收使用独立 `.productfixture` 包和短期测试 CA，不能把该变体的运行结果说成交付 APK 的逐字节实测。

普通路径是创建测试账号、按实例要求验证邮箱、首次初始化并完整重输离线恢复码、创建测试环境/变量、明确批准 CLI 的环境角色及期限。系统设备密码或强生物认证仍由 Android 保护钥匙。账号登录本身不授设备信任。

完整恢复、新 DAG 变量/环境及授权管理、全设备撤销、账号重置的未验入口仍保持默认关闭。不要把本试用拿来恢复唯一一份真实保险库。

## Linux 运行命令

使用独立 Linux VM 和预先建立的测试账号 `htrial`。下面的 ID、邮箱、地址必须替换成测试值。不要在真实工作账号运行。已持有 P5 固定原生工具的环境可复用，不需重跑 Linux 验收。

首次从源码构建工具时，在上述固定 core-go 源码的 Linux 目录中使用锁定工具链：

```sh
(cd pairing && mise run native-build)
mise exec go@1.26.4 -- go build -tags harmonia_boringssl -trimpath -o ./bin/harmonia ./cmd/harmonia
mise exec go@1.26.4 -- go build -trimpath -o ./bin/harmonia-linux-installer ./cmd/harmonia-linux-installer
```

配对 CLI 必须包含固定 BoringSSL/SPAKE2 原生实现，不能用 CGO0 构建冒充可配对程序。把审核后的二进制放到独立测试目录后，安装器按明确 UID 操作；遇现有未知文件会拒绝覆盖：

```sh
HARMONIA_TRIAL_UID="$(id -u htrial)"
HARMONIA_TRIAL_SOURCE=/srv/harmonia-trial/bin/harmonia
HARMONIA_TRIAL_SHA="$(sha256sum "$HARMONIA_TRIAL_SOURCE" | cut -d ' ' -f1)"
sudo /srv/harmonia-trial/bin/harmonia-linux-installer install --user htrial --uid "$HARMONIA_TRIAL_UID" --binary-source "$HARMONIA_TRIAL_SOURCE" --binary-sha256 "$HARMONIA_TRIAL_SHA"
```

在 `htrial` 自己的终端中登录与配对；密码在终端提示中输入，不放进命令参数或环境变量：

```sh
HARMONIA_TRIAL_UID="$(id -u)"
HARMONIA_TRIAL_BIN="/usr/local/lib/harmonia/$HARMONIA_TRIAL_UID/harmonia"
HARMONIA_TRIAL_STATE="/var/lib/harmonia/$HARMONIA_TRIAL_UID"
"$HARMONIA_TRIAL_BIN" login --local-directory "$HARMONIA_TRIAL_STATE" --server https://test-instance.example --email test-account@example.invalid
"$HARMONIA_TRIAL_BIN" pair --local-directory "$HARMONIA_TRIAL_STATE" --certificate-version 3 --approver '<手机设备ID>'
```

在手机按 CLI 显示的 PairID 和短码批准，明确选择一个测试环境及 RW/期限。配对成功后，由管理员启动该 UID 的后台：

```sh
sudo /srv/harmonia-trial/bin/harmonia-linux-installer start --user htrial --uid "$(id -u htrial)"
```

回到 `htrial` 的同一终端查看状态、激活环境，并只给当前 shell 装入 hook：

```sh
"$HARMONIA_TRIAL_BIN" status --local-directory "$HARMONIA_TRIAL_STATE"
"$HARMONIA_TRIAL_BIN" activate --local-directory "$HARMONIA_TRIAL_STATE" --environment '<环境ID>' --priority 10
eval "$("$HARMONIA_TRIAL_BIN" shell-hook --local-directory "$HARMONIA_TRIAL_STATE" --shell bash)"
```

上述 hook 示例用于 bash；zsh/sh 请把 `--shell bash` 改为对应 shell。只使用 `HARMONIA_TRIAL_VALUE` 等合成键验证手机改值后下发；不要扫描或导入真实 env。关闭 CLI 后服务仍运行。已有进程 env 无法被外部强改；sh 按已有 hook 调用 `harmonia_refresh`，bash/zsh 依提示符刷新。卸载在独立测试 VM 中用同一安装器 `uninstall --user htrial --uid '<UID>'`，不要手动删除整个状态目录。

## 验证边界

本次实际通过：JVM 真实 worker/main 两线程定向红绿验证，包含错误回传恰好一次、一个清理失败仍尝试剩余清理、健康查询保留 owner；固定 Go AAR 构建；arm64 调试 APK 构建。不是 Android Looper 运行测试的替代。

此前普通初始化、变量 CRUD、CLI 批准以及 Linux P5 后台/重启/卸载恢复证据复用，本段未重跑。不能据此声称当前 APK 与 Linux 的整条端到端链重新通过。本次最短 Android 原生尝试在测试驱动启动阶段失败（`DRIVER_EXITED`），发生在设置 PIN 前，凭据输入为 0。认证、登录、正式退出及退出后的材料清理断言均未执行，不能记为通过。已卸载本次测试包、停止本地测试服务并关闭本次新建模拟器；旧模拟器未触碰。详细结果见同目录 `validation/ANDROID_TRIAL_THREAD_RESULT.json`。按本段约定在新驱动阻塞处暂停，不重复诊断或运行。


## 调试签名

本分支使用独立测试签名，仓库不包含私钥。重新构建前，在 mobile 根目录的 `build/native` 中生成新的测试 keystore；已有同名文件时先核对来源，不覆盖：

```sh
mkdir -p build/native
(umask 077; test ! -e build/native/trial-debug.jks && keytool -genkeypair -keystore build/native/trial-debug.jks -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 3072 -validity 30 -dname 'CN=Harmonia Test')
```

这里的 `android` 是公开的调试口令，不能用于正式签名。重新生成的签名不能覆盖已安装的另一签名版本，APK 哈希也会改变。

## 后续最短原生流程已通过

修正独立 fixture 包名和测试构建 SDK 选择后，同一任务 AVD 已实际通过普通未受信登录、三次系统认证、正式退出与受保护材料删除；最终清理完成。原驱动、构建与首次选择器失败均保留。固定范围、实际 APK 摘要与限制见 [2026-10-04 后续记录](ANDROID_TRIAL_NATIVE_SHORT_20261004.md)。普通交付 APK 本身仍未按相同字节运行，本条不扩大为恢复/管理或整个 M2 通过。
