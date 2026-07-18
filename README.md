# ClashBox

## 介绍

ClashBox 是一个 HarmonyOS NEXT 平台的代理软件，使用改版的 ClashMate 内核。

注意：仓库中已包含可供应用构建的 `arm64-v8a/libflclash.so`，但该改版内核的完整源码并未全部开源。

## 在 DevEco Studio 中构建

1. 使用包含子模块的方式获取源码：

   ```shell
   git clone --recursive <repository-url>
   ```

   已经 clone 的仓库可执行 `git submodule update --init --recursive`。

2. 用支持 Hvigor `modelVersion: 5.1.0` 的 DevEco Studio 打开仓库根目录，安装 HarmonyOS 6.1.0(23) SDK，然后等待 OHPM 同步完成。项目宣告的最低兼容版本为 5.0.5(17)；如果同步时提示不支持 `modelVersion 5.1.0`，应升级 DevEco Studio/Hvigor，不要为了绕过检查盲目降低该版本号。

3. 仓库不再提交任何签名证书、profile、keystore 路径或口令。未配置签名时可生成未签名产物，但不能直接安装；需要在设备上运行/安装时，请在 DevEco Studio 的项目签名配置中为 `default` 产品启用本机自动签名，或选择你自己的调试签名材料。如果自动签名提示原 `bundleName` 不可用，请把 `AppScope/app.json5` 中的 `bundleName` 换成你自己的唯一值。

4. 选择 `entry` 模块、`default` 产品和 `debug` 构建模式，再在 DevEco Studio 中执行 Build Hap(s)/Run。

### ABI 限制

当前仓库只提供 `arm64-v8a` 版本的 `libflclash.so`，因此默认配置只构建 ARM64 产物，可用于 ARM64 真机。x86_64 模拟器缺少对应内核库，不能仅通过把 `abiFilters` 改回 `x86_64` 来运行。

### 可选：重新编译内核

普通的 DevEco Studio 应用构建会直接使用仓库内的预编译 `libflclash.so`，不需要执行 `proxy_core/src/flclash/build.sh` 或 `build.ps1`。

如果你有完整内核源码并需要重新编译，请先设置：

- `DEVECO_SDK_HOME`：DevEco Studio 的 SDK 根目录；或直接设置 `OHOS_NATIVE_HOME` 指向 `openharmony/native`。
- `GO_OHOS_BIN`：支持 `-tlsmodegd` 的 go-ohos 可执行文件；未设置时使用 `PATH` 中的 `go`。
- `BUILD_ARCH`：可选，默认为 `arm64`。

## 安装

也可使用 [Auto-installer](https://github.com/likuai2010/auto-installer/) 安装已签名的 HAP。
