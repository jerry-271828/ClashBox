import { vpnExtension, socket } from '@kit.NetworkKit';
import {
  startTun, stopTun, setFdMap, getVpnOptions, startLog, getProxies, getTraffic,
  getTotalTraffic,
  getExternalProviders,
  asyncTestDelay,
  updateConfig,
  initClash,
  changeProxy,
  forceGc,
  updateExternalProvider,
  getCountryCode,
  updateGeoData,
  sideLoadExternalProvider,
  getConnections,
  closeConnections,
  closeConnection,
  validateConfig,
  registerMessage,
  getRequestList,
  clearRequestList,
  startListener,
  stopListener
} from 'libflclash.so';
import {
  Address,
  AddressWithPrefix,
  cidrToRoute,
  CommonVpnService,
  VpnConfig
} from './CommonVpnService';
import { JSON, util } from '@kit.ArkTS';
import { RpcRequest, RpcResult } from './RpcRequest';
import { ClashRpcType } from './IClashManager';
import { ConnectionInfo, LogInfo, Provider, ProxyGroup, ProxyMode, ProxyType, Traffic } from '../models/Common';
import { getHome, getProfilePath } from '../appPath';
import { ClashConfig, Tun, UpdateConfigParams } from '../models/ClashConfig';
import { readFile, readFileUri, readText } from '../fileUtils';

export interface AccessControl {
  mode: string
  acceptList: string[]
  rejectList: string[]
  isFilterSystemApp: boolean
}
export interface VpnOptions {
  enable: boolean,
  port: number,
  ipv4Address: string,
  ipv6Address: string,
  accessControl: AccessControl,
  systemProxy: boolean,
  allowBypass: boolean,
  routeAddress: string[],
  bypassDomain: string[],
  dnsServerAddress: string,
}


export class FlClashVpnService extends CommonVpnService {
  vpnConnection: vpnExtension.VpnConnection | undefined
  public configPath: string = ""
  protectSocketPath: string = ""
  private protectSocket: socket.LocalSocket | undefined
  private protectBuffer: string = ""
  private protectDecoder: util.TextDecoder = new util.TextDecoder()

  override async onRemoteMessageRequest(client: socket.LocalSocketConnection, message: socket.LocalSocketMessageInfo): Promise<void> {
    let decoder = new util.TextDecoder()
    let request = JSON.parse(decoder.decodeToString(new Uint8Array(message.message))) as RpcRequest
    let code = request.method
    let params = request.params
    try {
      let result = await this.onRemoteMessage(code, params)
      this.sendClient(client, JSON.stringify({ result: result, error: undefined }))
    } catch (e) {
      console.error(`socket stub ${code} result: `, e.message ?? e, e.stack)
      this.sendClient(client, JSON.stringify({ error: e.message ?? e }))
    }
  }
  onRemoteMessage(code: number, data: (string | number | boolean)[]): Promise<string | number | boolean> {
    // 根据code处理客户端的请求
    return new Promise(async (resolve, reject) => {
      switch (code) {
        case ClashRpcType.startClash: {
          startListener()
          this.startVpn().then((r) => {
            if (!r) {
              stopListener()
            }
            resolve(r)
          }).catch((e: Error) => {
            stopListener()
            reject(e)
          })
          break;
        }
        case ClashRpcType.stopClash: {
          stopListener()
          this.stopVpn()
          resolve(true)
          break;
        }
        default: {
          resolve("不支持当前操作")
        }
      }
    })
  }

  ParseConfig(): VpnConfig {
    let vpnConfig = new VpnConfig();
    let option = JSON.parse(getVpnOptions()) as VpnOptions
    if (option.ipv6Address == undefined || option.ipv6Address == "") {
      option.ipv6Address = "fdfe:dcba:9876::1/126"
    }
    if (option.routeAddress == undefined) {
      option.routeAddress = []
    }
    if (option.ipv4Address != "") {
      const ips = option.ipv4Address.split("/")
      console.debug("tunIp ", ips)
      const prefixLength = ips.length > 1 ? parseInt(ips[1]) : 30
      vpnConfig.addresses[0] = new AddressWithPrefix(new Address(ips[0], 1), prefixLength)
      vpnConfig.isIPv4Accepted = true
    }
    if (option.ipv6Address != "") {
      const ips = option.ipv6Address.split("/")
      const prefixLength = ips.length > 1 ? parseInt(ips[1]) : 126
      vpnConfig.addresses.push(new AddressWithPrefix(new Address(ips[0], 2), prefixLength))
      vpnConfig.isIPv6Accepted = true
    }
    const routeAddresses: string[] = []
    const addRouteAddress = (cidr: string) => {
      if (cidr != "" && !routeAddresses.includes(cidr)) {
        routeAddresses.push(cidr)
      }
    }
    // Explicit defaults avoid OHOS auto-generating only fe80::/derived IPv6 coverage.
    option.routeAddress?.forEach(addRouteAddress)
    if (option.ipv4Address != "") {
      addRouteAddress("0.0.0.0/0")
    }
    if (option.ipv6Address != "") {
      addRouteAddress("::/0")
    }
    routeAddresses.forEach((cidr) => {
      const route = cidrToRoute(cidr)
      if (route != null) {
        vpnConfig.routes.push(route)
      }
    })
    if (option.accessControl?.mode) {
      if (option.accessControl?.mode == "AcceptSelected") {
        vpnConfig.trustedApplications = option.accessControl?.acceptList
      } else {
        vpnConfig.blockedApplications = option.accessControl?.rejectList
      }
    }
    if (option.systemProxy || option.allowBypass) {
      // TODO ohos 不支持
      // not use option.bypassDomain option.port
    }
    console.debug("vpnConfig", JSON.stringify(vpnConfig))
    return vpnConfig;
  }
  override async startVpn(): Promise<boolean> {

    let config = this.ParseConfig();
    let tunFd = -1
    try {
      tunFd = await super.getTunFd(config)
      if (tunFd > -1) {
        await this.startClash(tunFd)
      }
      return tunFd > -1;
    } catch (error) {
      console.error("ClashVPN  error ", error)
      this.closeProtectSocket()
      super.stopVpn()
      return false
    }
  }

  private handleProtectMessage(value: socket.LocalSocketMessageInfo): void {
    const chunk = this.protectDecoder.decodeToString(new Uint8Array(value.message), { stream: true })
    this.protectBuffer += chunk

    let separatorIndex = this.protectBuffer.indexOf("EOF")
    while (separatorIndex >= 0) {
      const frame = this.protectBuffer.substring(0, separatorIndex)
      this.protectBuffer = this.protectBuffer.substring(separatorIndex + 3)
      if (frame.length > 0) {
        this.protectFd(frame)
      }
      separatorIndex = this.protectBuffer.indexOf("EOF")
    }

    if (this.protectBuffer.length > 64 * 1024) {
      console.error("ClashVPN protect channel frame exceeded limit")
      this.protectBuffer = ""
    }
  }

  private async protectFd(frame: string): Promise<void> {
    try {
      const json = JSON.parse(frame) as RpcResult
      const fd = JSON.parse(json.result as string) as Fd
      await this.protect(fd.value)
      setFdMap(fd.id)
    } catch (e) {
      console.error("ClashVPN protect error", e.message)
    }
  }

  private closeProtectSocket(): void {
    const tcp = this.protectSocket
    this.protectSocket = undefined
    this.protectBuffer = ""
    this.protectDecoder = new util.TextDecoder()
    if (tcp) {
      tcp.close().catch((e: Error) => {
        console.error("ClashVPN close protect channel error", e.message)
      })
    }
  }

  async startClash(tunFd: number): Promise<void> {
    this.closeProtectSocket()
    const tcp: socket.LocalSocket = socket.constructLocalSocketInstance();
    this.protectSocket = tcp
    tcp.on('message', (value: socket.LocalSocketMessageInfo) => {
      this.handleProtectMessage(value)
    })
    tcp.on('error', (e: Error) => {
      console.error("ClashVPN protect channel error", e.message)
    })
    tcp.on('close', () => {
      if (this.protectSocket === tcp) {
        this.protectSocket = undefined
        this.protectBuffer = ""
      }
      console.warn("ClashVPN protect channel closed")
    })
    const socketPath = this.context?.filesDir + '/clash_go.sock'
    console.error("ClashVPN connect", tunFd)
    try {
      await tcp.connect({ address: { address: socketPath }, timeout: 3000 })
      console.error("ClashVPN connect", tunFd)
      await tcp.send({ data: JSON.stringify({ method: ClashRpcType.startClash, params: [tunFd] }) });
    } catch (e) {
      console.error("ClashVPN  error ", e.message, e)
      this.closeProtectSocket()
      throw e
    }
  }


  stopVpn() {
    this.closeProtectSocket()
    stopTun()
    super.stopVpn()
  }
  override async init() {
    initClash(await getHome(this.context), "1.0.0")
  }
}

export interface Fd {
  id: number
  value: number
}

export function ParseProxyGroup(mode, result: string): ProxyGroup[] {
  if (result == null)
    return []
  const map = JSON.parse(result) as Record<string, string | Record<string, string[] | string>>
  const global = map[ProxyMode.Global]
  let groupNames = global?.["all"] as string[] ?? []
  if (mode == ProxyMode.Global) {
    groupNames = ["GLOBAL", ...groupNames]
  } else if (mode == ProxyMode.Rule) {
    groupNames = groupNames
  } else {
    groupNames = []
  }
  groupNames = groupNames.filter(e => {
    const proxy = map[e] as Record<string, string>
    if (!proxy)
      return false
    const indexes = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"].indexOf(proxy["type"])
    return indexes > -1
  })
  const groupsRaw = groupNames.map((groupName) => {
    const group = map[groupName];
    if (group){
      group["proxies"] = (group["all"] ?? []).map((n: string) => {
        if(!map[n]){
          return;
        }
        map[n]["name"] = map[n]?.["name"]
        return map[n]
      }).filter((d: string) => d != null && d != undefined)
      return {
        name: group["name"] as string,
        now: group["now"] as string,
        type: group["type"] as ProxyType,
        hidden: group["hidden"] == true,
        icon: group["icon"] as string,
        proxies: group["proxies"]
      } as ProxyGroup
    } else {
      return null;
    }
  })
  return groupsRaw.filter(g => g != null);
}
