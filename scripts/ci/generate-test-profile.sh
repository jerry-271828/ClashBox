#!/usr/bin/env bash
# Regenerate signing/clashboxLTS-release.p7b (OpenHarmony test key, type=release)
# for local DevEco builds. Requires a DevEco/OHOS SDK with toolchains/lib containing
# hap-sign-tool, UnsgnedReleasedProfileTemplate.json, OpenHarmony*.p12/pem.
#
# Usage:
#   scripts/ci/generate-test-profile.sh [sdk-toolchains-lib]
#
# Without an argument, tries $OHOS_SDK_HOME/toolchains/lib, then the default
# DevEco Studio SDK location on macOS.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGNING_DIR="$REPO_ROOT/signing"
BUNDLE_NAME="${HAP_BUNDLE_NAME:-org.xbgroup.clashboxLTS}"

if [[ $# -ge 1 ]]; then
  SDK_LIB="$1"
elif [[ -n "${OHOS_SDK_HOME:-}" ]]; then
  SDK_LIB="$OHOS_SDK_HOME/toolchains/lib"
else
  SDK_LIB="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib"
fi

SIGN_TOOL="$SDK_LIB/hap-sign-tool"
if [[ ! -x "$SIGN_TOOL" && -f "$SDK_LIB/hap-sign-tool.jar" ]]; then
  SIGN_TOOL=(java -jar "$SDK_LIB/hap-sign-tool.jar")
fi

for f in UnsgnedReleasedProfileTemplate.json OpenHarmony.p12 \
         OpenHarmonyApplication.pem OpenHarmonyProfileRelease.pem; do
  test -s "$SDK_LIB/$f" || { echo "missing $SDK_LIB/$f" >&2; exit 1; }
done

NODE_BIN="$(command -v node || true)"
test -n "$NODE_BIN" || { echo "node not found in PATH" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$NODE_BIN" "$REPO_ROOT/scripts/ci/create-openharmony-profile.mjs" \
  "$SDK_LIB/UnsgnedReleasedProfileTemplate.json" \
  "$TMP/profile.json" \
  "$BUNDLE_NAME"

"$SIGN_TOOL" sign-profile \
  -mode localSign \
  -keyAlias "openharmony application profile release" \
  -keyPwd "123456" \
  -profileCertFile "$SDK_LIB/OpenHarmonyProfileRelease.pem" \
  -inFile "$TMP/profile.json" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$SDK_LIB/OpenHarmony.p12" \
  -keystorePwd "123456" \
  -outFile "$SIGNING_DIR/clashboxLTS-release.p7b"

echo "wrote $SIGNING_DIR/clashboxLTS-release.p7b (bundle: $BUNDLE_NAME)"
