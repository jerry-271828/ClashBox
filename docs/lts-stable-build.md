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

## HarmonyOS 7 extension sandbox restriction — verified findings

Symptom (HarmonyOS 7.0.0.102, Beta2, QXS-W00): with some installs the `:vpn`
extension gets `LocalSocketServer.listen` → 2301013 "Insufficient permissions"
(errno 13) for Unix socket binds in every app directory, so the extension-hosted
core (mihomo) cannot start and the UI shows "vpn服务启动失败".

Verified on-device facts (2026-08-14):

- A debug-probe build logged `[BIND-PROBE] unix-*=FAIL 2301013 | tcp-*=OK`
  for installs that carried the app `debug:false` flag together with a debug
  certificate (manually signed release-mode HAPs).
- A DevEco default build (debug build mode, automatic signing with the Huawei
  developer debug certificate) reports `debug:true` and the probe flips to
  `unix-filesDir=OK | unix-cacheDir=OK | unix-tempDir=OK | unix-databaseDir=OK`.
  The full mihomo pipeline then works (bind sockets, create TUN, hand fd to the
  core).
- The store build (release provision, app_gallery) was never restricted.

Conclusion: on this device the operative lever was the HAP debug flag /
build mode, not the certificate type. The Huawei forum answer
("Debug包访问沙箱文件失败问题处理") describes the 7.0 beta1 debug-hap
tightening; on Beta2 the remaining reproducible restriction hit
release-mode-claimed (`debug:false`) HAPs signed with debug certificates.
The exact policy is not fully pinned down.

Practical guidance:

- Local use on HarmonyOS 7: build with DevEco Studio's default flow
  (debug build + automatic signing). This is what works. Local signing is
  configured per-machine via DevEco's Project Structure > Signing Configs
  (it writes machine-local paths and encrypted passwords into
  `build-profile.json5`; those changes must stay uncommitted).
- CI: both workflows now assemble with `buildMode=debug` (HAP carries
  `debug:true`, matching the verified-working DevEco default build).
  - Best fidelity: configure the six `HAP_SIGNING_*` secrets with your own
    Huawei debug-certificate material (the same `.p12`/`.cer`/`.p7b` DevEco
    uses) — CI output then equals the locally verified combination.
  - Fallback (no secrets): the OpenHarmony test key with the `type=release`
    profile (kept release-type on purpose — the debug-type test template
    hardcodes foreign device-ids and would not install). This combination
    installs on developer-mode devices but was not re-verified for the
    mihomo mode on HarmonyOS 7; verify once before relying on it.
