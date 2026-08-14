import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { CommonVpnService } from './CommonVpnService';
import { FlClashVpnService } from './FlClashVpnService';
import { startIpc } from 'libflclash.so';
import fs from "@ohos.file.fs"


export class SocketStubService {
  server: socket.LocalSocketServer = socket.constructLocalSocketServerInstance();
  clientPool: Map<number, socket.LocalSocketConnection>
  vpnService: CommonVpnService
  constructor( context: common.Context) {
    this.clientPool = new Map()
    this.vpnService = new FlClashVpnService(context)
    this.vpnService.init()
  }

  async startService(){
    await this.probeBindCapabilities()
    try {
      const socketPath = this.vpnService.context.filesDir + '/ClashBox.sock'
      const goPath = this.vpnService.context.filesDir + '/clash_go.sock'
      startIpc(goPath)

      // 上次进程异常退出/系统升级后会残留陈旧 socket 文件，
      // 不清理的话 listen 会报 EADDRINUSE (Address in use) 导致启动失败
      try {
        fs.unlinkSync(socketPath)
      } catch (e) {
        console.warn(`SocketStubService 清理陈旧 socket 失败: ${JSON.stringify(e)}`)
      }

      await this.server.listen({ address: socketPath})
      this.server.on('connect', (client: socket.LocalSocketConnection) => {
          this.clientPool.set(client.clientId, client);
          client.on("message", (value: socket.LocalSocketMessageInfo) => {
            this.vpnService.onRemoteMessageRequest(client, value)
          })
          client.on('close', () => {
            client.off("message")
            client.off("close")
            this.clientPool.delete(client.clientId);
          });
      })
    } catch (e) {
      console.error("socket failure", e.message)
    }
  }

  /**
   * 鸿蒙7诊断:检测 VPN 扩展进程在沙箱内可用的 IPC 传输方式。
   * 结果以 [BIND-PROBE] 前缀输出到 hilog。
   */
  async probeBindCapabilities() {
    const results: string[] = []
    // 1) unix socket 在不同应用目录
    const dirNames: string[] = ['filesDir', 'cacheDir', 'tempDir', 'databaseDir']
    const dirPaths: (string | undefined)[] = [
      this.vpnService.context.filesDir,
      this.vpnService.context.cacheDir,
      this.vpnService.context.tempDir,
      this.vpnService.context.databaseDir,
    ]
    for (let i = 0; i < dirNames.length; i++) {
      const name = dirNames[i]
      const dir = dirPaths[i]
      if (dir == undefined) {
        results.push(`unix-${name}=NODIR`)
        continue
      }
      const p = dir + '/probe_' + name + '.sock'
      const s = socket.constructLocalSocketServerInstance()
      try {
        await s.listen({ address: p })
        results.push(`unix-${name}=OK`)
        s.close()
      } catch (e) {
        results.push(`unix-${name}=FAIL ${JSON.stringify(e)}`)
      }
      try {
        fs.unlinkSync(p)
      } catch (e) {
        // ignore
      }
    }
    // 2) TCP 监听
    const tcpNames: string[] = ['tcp-any', 'tcp-loopback']
    const tcpAddrs: string[] = ['0.0.0.0', '127.0.0.1']
    for (let i = 0; i < tcpNames.length; i++) {
      const name = tcpNames[i]
      const addr: socket.NetAddress = { address: tcpAddrs[i], port: 0, family: 1 }
      const t = socket.constructTCPSocketServerInstance()
      try {
        await t.listen(addr)
        results.push(`${name}=OK`)
        t.close()
      } catch (e) {
        results.push(`${name}=FAIL ${JSON.stringify(e)}`)
      }
    }
    console.error(`[BIND-PROBE] ${results.join(' | ')}`)
  }
  startVpn(){
    this.vpnService.startVpn()
  }
  stopVpn(){
    this.vpnService.stopVpn()
  }
}
function sleepTime(timeout = 100): Promise<void>{
  return new Promise((resolve)=>{
    setTimeout(resolve, timeout)
  })
}