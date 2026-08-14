# ClashBox LTS stable build (long-lived connections)

This branch (`fix/lts-stable-long-connections`) packages the **public ClashBox
LTS** line as a stable replacement for the unpublished store V2 build.

## Why

The store V2 build (`org.xbgroup.clashbox`, 2.0.x) periodically wipes all
active connections: a UI-process ArkTS timer fires about every 180.5 s while
the UI runtime is executing and invokes RPC `ClearConnections` (method 11) on
the embedded core. Every active TCP/WebSocket flow — TUN/Fake-IP and localhost
mixed-port alike — then receives an orderly FIN within the same millisecond
window. Details: `INVESTIGATION-2026-08-11-synchronized-fin.md` (not part of
upstream source).

Public LTS contains the destructive `ClearConnections` handler only behind the
**manual** "clear connections" action and has no automatic caller
(audit: `docs/lts-connection-lifecycle-audit.md`). No behavioral patch is
required; this build deliberately changes nothing in the app logic.

## What this build is

- Source: public LTS `master` @ `1fdc47eb` + the reproducible-build CI from
  `ci/ohos-core-build` (vendored `xb_components`, pinned core/gVisor/Go
  toolchain, OpenHarmony test-key or `HAP_SIGNING_*` secret signing).
- Bundle: `org.xbgroup.clashboxLTS` — coexists with store V2; run only one
  VPN at a time.
- Version identity: `1.7.4-lts-stable.1` (versionCode 1007048).
- Instrumented variant for RPC/close-event tracing lives separately on
  `diag/close-trigger-instrumented` and is not part of this build.

## Validation focus

Long-lived WSS/TCP flows must survive indefinitely across UI foreground,
minimize/restore, and background use; manual "clear connections" must still
work. See the validation section of the investigation notes.

## HarmonyOS 7 (API 26) upgrade compatibility — stale-socket crash fix

Symptom after an OS upgrade (HarmonyOS 6 → 7.0.0, QXS-W00 7.0.0.102): the app
opens, the UI toasts `获取代理失败: connectionrefused undefined` (actually
`Connection refused`), and the VPN extension process dies on every start.

Root cause (evidence: hilog + `hidumper -e` cppcrash records, 2026-08-14):

- The OS upgrade preserves `filesDir`, including Unix socket files
  `clash_go.sock` / `ClashBox.sock` left by earlier sessions.
- On the next start the Go IPC listener (`flclash/ipc.go`) hits
  `bind: address already in use`; the old code logged the error but then ran
  `defer listener.Close()` on the nil listener → Go fatal panic → SIGSEGV →
  the whole `:vpn` extension process is killed by DFX (CppCrash), leaving the
  stale files behind again (crash loop: 20:34, 20:37, 20:38, 21:07, 21:09×6,
  21:14, 21:16 on one day).
- The ArkTS side failed the same way: `LocalSocketServer.listen` on the stale
  `ClashBox.sock` → EADDRINUSE.
- With no core listener, the UI's RPC connect gets ECONNREFUSED (errno 111) →
  `vpn服务启动失败 Connection refused` / `获取代理失败`.

Fixes (this branch):

- `proxy_core/src/flclash/ipc.go`: return instead of dereferencing the nil
  listener when the Unix bind fails (no more fatal panic).
- `proxy_core/src/main/ets/rpc/SocketStubService.ets`: unlink stale
  `ClashBox.sock` before `listen`.
- `entry/src/main/ets/entryability/ClashViewModel.ets`: on the VPN restart
  path, the UI process unlinks both stale socket files before starting the
  extension (self-heals after upgrades/abnormal exits even when the extension
  process itself cannot remove them).

Device-side recovery for already-broken installs: clear the app's data once
(`bm clean -n org.xbgroup.clashboxLTS -d`) or reinstall; verified on
HarmonyOS 7.0.0.102 that the extension then starts and survives force-stop /
restart cycles, and the core serves RPC again (`loadConfig` succeeds).

## HarmonyOS 7 debug-hap sandbox restriction — release provisioning

Official Huawei forum answer (topic "Debug包访问沙箱文件失败问题处理", 2026-07-14):
HarmonyOS 7.0 beta1 tightened sandbox permissions for **debug-signed** haps —
after the VpnExtension process starts, sandbox file operations (including
binding Unix sockets, `LocalSocketServer.listen`) fail with permission-denied
errors (socket error 2301013 / errno 13). AppGallery **release** haps are
unaffected; the system-side fix ships in HarmonyOS 7.0 beta2.

Consequences for this repo:

- Local DevEco builds signed with a developer **debug** certificate hit the
  restriction: the `:vpn` extension cannot bind `clash_go.sock`/`ClashBox.sock`
  on affected builds.
- The OpenHarmony **test** signing material ships a `type=release` profile
  (`app-distribution-type: os_integration`), so CI test-signed builds are
  release-provisioned and avoid the restriction.

Local build setup (DevEco Studio):

- `build-profile.json5` ships a `signingConfigs.release` entry bound to
  `signing/` (OpenHarmony test key, passwords `123456`, profile
  `clashboxLTS-release.p7b` with `type=release`). Both products reference it,
  so DevEco signs release-provisioned packages by default.
- Regenerate the profile after changes: `scripts/ci/generate-test-profile.sh
  [sdk-toolchains-lib]` (auto-detects DevEco's macOS SDK path).
- If you have AGC release certificates, replace the `material` entries with
  your `.p12` / `.cer` / `.p7b` and remove the shipped test profile.
