# ClashBox 项目经验 (AGENTS.md)

面向在本仓库工作的编码代理。以下经验来自 HarmonyOS 7 升级适配实战(2026-08)，多为踩坑换来的结论，改动相关代码前先读一遍。

## 架构速览

- 应用 = UI 进程(`entry`/EntryAbility) + VPN 扩展进程(`:vpn`/ClashVpnAbility)。
- 两种内核模式(设置 → 内核)：
  - **前台模式(ClashMeta，默认)**：核心跑在 **UI 进程**(EntryAbility.ClashCoreInit 里 `new SocketStubService(this.context)`)，扩展只做透传。
  - **新内核(mihomo)**：核心跑在 **VPN 扩展进程**(ClashVpnAbility.onCreate 里 `new SocketStubService(...)`)，Go 内核为 `proxy_core/libs/arm64-v8a/libflclash.so`。
- 进程间 RPC 走 filesDir 下的 unix socket：`clash_go.sock`(核心 RPC)、`ClashBox.sock`(start/stop 桩)，JSON 消息 + "EOF" 分隔。
- Go 内核源码在 `proxy_core/src/flclash/`(wrapper) + 子模块 `core`/`gvisor-ohos`(CI 按 pin 拉取)。

## HarmonyOS 7 (API 26) 关键结论

1. **debug 构建模式是杠杆**：在 7.0.0.102(Beta2)上，`buildMode=release` 构建(debug:false) + 调试证书签名的包，其 VPN 扩展进程会被沙箱限制——unix socket bind 全部报 `2301013 Insufficient permissions`(errno 13)。**DevEco 默认 debug 构建(debug:true) + 自动签名正常**，商店 release 包不受影响。CI 必须用 `buildMode=debug`。华为论坛"Debug包访问沙箱文件失败问题处理"讲的是 beta1 的 debug 收紧(beta2 修复)，与本机实测不完全一致，确切策略未完全钉死。
2. **扩展进程冷启动竞态**：扩展由系统异步拉起(数百毫秒)，期间 `clash_go.sock` 可能不存在，也可能是**上次会话遗留的陈旧文件(路径存在但无监听者)**。就绪判断必须以"**能否 connect 成功**"为准(探测连接 + 有界重试)，不能以"文件存在"为准。
3. **VPN 活跃时扩展难以被杀**：`aa force-stop` 不会杀掉活跃 VPN 的扩展；`stopVpnExtensionAbility` 可能要 ~20 秒才落地。冷启动就绪等待要容忍这个延迟。
4. 设备指纹：`param get const.product.os.dist.releasetype` = Beta2；`const.ohos.apiversion` = 26。

## 不能回退的修复(改 IPC/socket 代码前必读)

- `proxy_core/src/flclash/ipc.go`：bind 失败必须 `return`，**绝不**在 bind 失败后使用 nil listener(defer Close 会触发 Go fatal panic → SIGSEGV → 整个扩展进程被 DFX 杀)。
- 陈旧 socket 清理：扩展侧 `SocketStubService.startService` listen 前 unlink；UI 侧 `ClashViewModel.ChangeCore` 在 mihomo 路径重启前 unlink 两个 socket 文件。删掉任何一处都会复现"connectionrefused"崩溃循环。
- 就绪等待(`SocketProxyService.waitForSocketAccepting`)：探测连接(connect 后立即 close)有界重试，别改回"文件存在"检查。
- `ClashViewModel.waitVpnAbilityReady`：轮询 `vpn_ipc.lock` 直到写入当前 requestId(有界)，单次检查会被旧会话锁文件误判。
- 错误提示拼接用 `?? ''` 兜底，避免拼出字面 "undefined"。

## 构建与签名规则(安全红线)

- **绝不提交签名配置到 `build-profile.json5`**：hvigor 的 SignHap 要求 DevEco 加密格式的密码(明文会被 00303116 拒绝)。本地签名配置(机器路径 + 加密密码)由 DevEco Project Structure 写入，**保持未提交**。
- **绝不读取/复制/提交开发者的证书、私钥、签名材料**。CI secrets 由所有者自己在 GitHub 配置；本仓库流程默认"CI 出未签名包 + 本地自行签名"。
- CI 两工作流均用 `buildMode=debug`；`scripts/ci/sign-hap.sh` 兜底用 OpenHarmony 公开测试证书(release 类型 profile——debug 模板硬编码外国设备 udid，装不上)。装包后用 `bm dump -n <bundle>` 看 `debug` 标志应为 true。
- 版本升级记得同时改 `AppScope/app.json5` 的 versionCode/versionName，再打 tag 走 Release。

## 本机诊断速查

- hdc：`/storage/Users/currentUser/.harmonybrew/bin/hdc`；设备目标 `127.0.0.1:12345`(需用户先起 hdcd)。
- 崩溃栈：`hidumper -e --print <record_id>`；崩溃列表：`hidumper -e --list org.xbgroup.clashboxLTS`。
- 日志：`hdc -t ... hilog -x`；Go 内核日志 tag `flclashGo`(VPN 跑起来后可见)。
- 包信息：`bm dump -n org.xbgroup.clashboxLTS`(appProvisionType/debug/apiTargetVersion)。
- GitHub 直连慢/不通时，下载走 `https://v6.gh-proxy.org/<github-url>`。

## 修复验证清单(改动后自测)

1. 普通冷启动：无"VPN服务启动失败/获取代理失败"弹窗；
2. VPN 开着时重启应用：同样无弹窗；
3. 切新内核后：扩展进程存活、`[启用核心 mihomo 成功]`、TUN 起来(`ClashVPN 获取tunFd`)；
4. 强停/重启多次无新 CppCrash 记录(`hidumper -e --list`)。
