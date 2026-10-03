# iOS Simulator 产品注册与邮件证明

2026-10-03 在独立 iOS 27.0 arm64 Simulator 中，实际 Harmonia Flutter 产品完成合成账号注册与邮件证明。服务端各记录一次尝试、一次接受。此结果不代表设备已经可信，也不代表真机硬件验收。

## 执行来源

执行包仍是 mobile `9e0a00b81ebe08b203d79ee246b434412c5a67fb` 加已公开于 `875ff1751461abedb3898785b839791b934254ee` 的 iOS fixture 接线，使用前次记录的 Debug 产物。没有将后续共享源码提交视为这次已执行的产品版本。

服务端为独立的 `bd86fec6215b6f7149234578e7bf5dc764a639c2` 空实例，TLS 地址固定 `https://127.0.0.1:5593`。通过公共 CA 的标准链与 hostname 校验，没有写系统 trust store；没有使用其它平台的账号、邮件或端口。

## 实际路径

先在空邮箱输入框验证公开字符串 `aA0_1:2`，确认官方 Simulator 键盘与正常 CGEvent 输入正确，再清空该串。合成密码由测试输入进程随机生成，只在该进程内存与遮蔽字段间传递，没有放入 argv、日志或截图；邮箱仅使用 fixture 允许的 `.invalid` 地址。

产品提交注册后清空密码字段，并实际显示 iOS 系统认证提示。通过官方 Device Hub 的 `Authorized with Face ID` 测试控制完成模拟认证；生产 Swift 原生桥完成受 ACL 保护的本机钥匙创建、Go workflow 与标准 HTTPS 注册。服务端 `registerAttempts=1`、`registerAccepted=1`，产品进入“验证邮箱”页。

测试输入进程通过相同局部 CA 读取该独立 fixture 捕获的唯一合成邮件，仅在内存解析证明并输入原产品表单。提交后字段清空，生产原生受保护路径完成邮件证明；服务端 `emailProofAttempts=1`、`emailProofAccepted=1`。界面进入“设置首台设备”，明确显示“本机还不是可信设备”。

本段只有一次观察到并明确完成的官方模拟 Face ID 提示。后续新 LAContext 的受保护取钥未出现第二次独立提示；不能据此声称每次都有独立物理认证或手机硬件因素。没有注入 LA 返回值、UI trusted bool 或模拟业务授权。

## 保留的未执行范围

本段没有提交账号登录、首台初始化、恢复、审批、管理写入或 pull；这些服务端计数为零。没有生成或截取恢复码。

后续初始化前改用固定公开 `8a0515c374dea6bd29e966e442c804b2222db7a7` 的独立 Debug 构建，以包含共用认证 resumed 等待与隐藏表单状态修复；本证据不追认新包已执行。
