$ErrorActionPreference = "Stop"

$arch = if ($env:BUILD_ARCH) { $env:BUILD_ARCH } else { "arm64" }
switch ($arch) {
    "arm64" {
        $target = "aarch64"
        $outdir = "arm64-v8a"
    }
    "amd64" {
        $target = "x86_64"
        $outdir = "x86_64"
    }
    default {
        throw "Unsupported BUILD_ARCH: $arch (expected arm64 or amd64)"
    }
}

$OHOS_NATIVE_HOME = $env:OHOS_NATIVE_HOME
if (-Not $OHOS_NATIVE_HOME) {
    if (-Not $env:DEVECO_SDK_HOME) {
        throw "Set DEVECO_SDK_HOME to the DevEco Studio SDK root, or set OHOS_NATIVE_HOME directly"
    }
    $OHOS_NATIVE_HOME = Join-Path $env:DEVECO_SDK_HOME "default/openharmony/native"
}
if (-Not (Test-Path (Join-Path $OHOS_NATIVE_HOME "sysroot")) -or
    -Not (Test-Path (Join-Path $OHOS_NATIVE_HOME "llvm"))) {
    throw "Invalid OHOS_NATIVE_HOME: $OHOS_NATIVE_HOME"
}

$GO_OHOS_BIN = if ($env:GO_OHOS_BIN) { $env:GO_OHOS_BIN } else { "go" }
$BASE_FLAGS = "-Wno-error --sysroot=$OHOS_NATIVE_HOME/sysroot -fdata-sections -D__MUSL__ -ffunction-sections -funwind-tables -fstack-protector-strong -no-canonical-prefixes -fno-addrsig -Wa,--noexecstack -fPIC"
$TOOLCHAIN = "$OHOS_NATIVE_HOME/llvm"

$env:CC = "$TOOLCHAIN/bin/clang"
$env:CXX = "$TOOLCHAIN/bin/clang++"
$env:LD = "$TOOLCHAIN/bin/clang"
$env:CGO_AR = "$TOOLCHAIN/bin/llvm-ar"
$CGO_AR = "$TOOLCHAIN/bin/llvm-ar"
$env:GOASM = "$TOOLCHAIN/bin/llvm-as"

$env:GOOS = "linux"
$env:GOARCH = $arch # amd64 386 arm arm64
$env:GOARM = ""
$env:CGO_ENABLED = "1"
$env:CGO_CXXFLAGS = ""
$env:CGO_CFLAGS = "-Wno-error --target=$target-linux-ohos  $BASE_FLAGS  "
$env:CGO_LDFLAGS = "-extld=$env:LD --sysroot=$OHOS_NATIVE_HOME/sysroot --target=$target-linux-ohos"

$outputFile = Join-Path $PSScriptRoot "libflclash.so"
# 压缩so
# -trimpath -ldflags="-s -w"
Push-Location $PSScriptRoot
try {
    & $GO_OHOS_BIN build -tlsmodegd -buildmode c-shared -tags "foss cmfa with_gvisor ohos" -v -o $outputFile "./"
    if ($LASTEXITCODE -ne 0) {
        throw "go-ohos build failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

# 检查编译结果
if (Test-Path $outputFile) {
    Write-Host "success: $outputFile"
}
else {
    Write-Host "failed"
}

# 如果拷贝目录不存在，则创建
$libsDirectory = "$PSScriptRoot\..\..\libs\$outdir"
if (-Not (Test-Path -Path $libsDirectory)) {
    New-Item -Path $libsDirectory -ItemType Directory -Force
    Write-Host "The target directory has been created: $libsDirectory"
}
Copy-Item -Force $outputFile (Join-Path $libsDirectory "libflclash.so")
#Copy-Item -Force "$PSScriptRoot\dist\index.d.ts" "$PSScriptRoot\..\src\main\cpp\types\hello\index.d.ts"
