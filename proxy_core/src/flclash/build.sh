#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

# 可通过 BUILD_ARCH=amd64 切换架构。默认与当前仓库内的预编译库保持一致。
arch="${BUILD_ARCH:-arm64}"
case "$arch" in
  arm64)
    target="aarch64"
    outdir="arm64-v8a"
    ;;
  amd64)
    target="x86_64"
    outdir="x86_64"
    ;;
  *)
    echo "Unsupported BUILD_ARCH: $arch (expected arm64 or amd64)" >&2
    exit 1
    ;;
esac

# OHOS_NATIVE_HOME 可直接指向 openharmony/native；否则从 DevEco SDK 根目录推导。
if [[ -z "${OHOS_NATIVE_HOME:-}" ]]; then
  : "${DEVECO_SDK_HOME:?Set DEVECO_SDK_HOME to the DevEco Studio SDK root, or set OHOS_NATIVE_HOME directly}"
  OHOS_NATIVE_HOME="$DEVECO_SDK_HOME/default/openharmony/native"
fi

if [[ ! -d "$OHOS_NATIVE_HOME/sysroot" || ! -d "$OHOS_NATIVE_HOME/llvm" ]]; then
  echo "Invalid OHOS_NATIVE_HOME: $OHOS_NATIVE_HOME" >&2
  exit 1
fi

# 必须使用支持 -tlsmodegd 的 go-ohos；可传入绝对路径，也可使用 PATH 中的命令。
GO_OHOS_BIN="${GO_OHOS_BIN:-go}"

# 基础编译标志
BASE_FLAGS="-Wno-error --sysroot=$OHOS_NATIVE_HOME/sysroot "

# 工具链路径
TOOLCHAIN="$OHOS_NATIVE_HOME/llvm"

# 设置环境变量
export CC="$TOOLCHAIN/bin/clang"
export CXX="$TOOLCHAIN/bin/clang++"
export LD="$TOOLCHAIN/bin/clang"
export CGO_AR="$TOOLCHAIN/bin/llvm-ar"
export GOASM="$TOOLCHAIN/bin/llvm-as"
export GOOS="linux"
export GOARCH="$arch"
export GOARM=""
export CGO_ENABLED="1"
export CGO_CXXFLAGS=""
export CGO_CFLAGS="-Wno-error --target=$target-linux-ohos $BASE_FLAGS"
export CGO_LDFLAGS=" --sysroot=$OHOS_NATIVE_HOME/sysroot --target=$target-linux-ohos"

# 源文件和输出文件
sourceFile="./"
outputFile="$script_dir/libflclash.so"

# 构建命令，生成共享库
"$GO_OHOS_BIN" build -tlsmodegd -buildmode c-shared -tags "ohos with_gvisor" \
  -gcflags="all=-N -l" -o "$outputFile" "$sourceFile"

# 检查编译结果
if [ -f "$outputFile" ]; then
    echo "success: $outputFile"
else
    echo "failed"
fi

# 复制生成的 .so 文件到指定目录
mkdir -p "$script_dir/../../libs/$outdir"
cp -f "$outputFile" "$script_dir/../../libs/$outdir/libflclash.so"
rm -f "$outputFile"


# ubex > gvisor@v0.0-20240320004321-933faba989ec > pkg>tcpip>link >fdbased>~60 endpoint.go
#isSocketFD
