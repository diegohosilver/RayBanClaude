/**
 * Network helpers: find the LAN address for the phone and detect local requests.
 */

import { networkInterfaces } from 'os'
import { HTTP_DEFAULT_PORT } from './constants.ts'
import {
  CGNAT_100, LAN_10, LAN_172, LAN_192, LINK_LOCAL, PORT_SUFFIX, TAILSCALE_IFACE, VIRTUAL_IFACE, WIFI_IFACE,
} from './patterns.ts'

export interface LanIp {
  readonly address: string
  readonly iface: string
  readonly rank: number
}

/** Address ranges in descending priority: home network first, Tailscale last. */
const RANGE_PRIORITY: readonly RegExp[] = [LAN_192, LAN_10, LAN_172, CGNAT_100]
const IPV4 = 'IPv4'
/** Gap between two ranges so the Wi-Fi bonus never skips a range. */
const RANK_STEP = 2

function rankAddress(address: string, iface: string): number {
  const rangeIndex = RANGE_PRIORITY.findIndex(r => r.test(address))
  const rangeRank = rangeIndex === -1 ? RANGE_PRIORITY.length : rangeIndex
  // Virtual adapters (WSL, Hyper-V, VMs) go last – the phone never reaches them
  const virtualPenalty = VIRTUAL_IFACE.test(iface) && !TAILSCALE_IFACE.test(iface) ? RANGE_PRIORITY.length + 1 : 0
  const wifiBonus = WIFI_IFACE.test(iface) ? -1 : 0
  return (rangeRank + virtualPenalty) * RANK_STEP + wifiBonus
}

/** All IPv4 addresses of this PC, best candidates for the phone first. */
export function listLanIps(): readonly LanIp[] {
  return Object.entries(networkInterfaces())
    .flatMap(([iface, nets]) => (nets ?? []).map(net => ({ iface, net })))
    .filter(({ net }) => net.family === IPV4 && !net.internal && !LINK_LOCAL.test(net.address))
    .map(({ iface, net }) => ({ address: net.address, iface, rank: rankAddress(net.address, iface) }))
    .sort((a, b) => a.rank - b.rank)
}

/**
 * Tailscale address of this PC (100.64.0.0/10), if Tailscale is running. Through it
 * the iPhone can reach the PC on the go too – encrypted, without port forwarding.
 */
export function findTailscaleIp(ips: readonly LanIp[] = listLanIps()): string | undefined {
  const byName = ips.find(ip => TAILSCALE_IFACE.test(ip.iface) && CGNAT_100.test(ip.address))
  return (byName ?? ips.find(ip => CGNAT_100.test(ip.address)))?.address
}

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1'])
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]'])
const IPV6_LOOPBACK = '::1'

function isLocalHostname(hostname: string): boolean {
  return LOCAL_HOSTS.has(hostname === IPV6_LOOPBACK ? '[::1]' : hostname)
}

/**
 * Only genuine requests from this PC: sender IP is loopback, Host header is
 * localhost (protection against DNS rebinding) and any Origin belongs to the dashboard.
 */
export function isLocalRequest(req: Request, remoteIp: string, port: number): boolean {
  if (!LOOPBACK.has(remoteIp)) return false
  const host = (req.headers.get('host') ?? '').toLowerCase().replace(PORT_SUFFIX, '')
  if (!isLocalHostname(host)) return false
  const origin = req.headers.get('origin')
  if (!origin) return true
  if (!URL.canParse(origin)) return false
  const o = new URL(origin)
  return isLocalHostname(o.hostname) && Number(o.port || HTTP_DEFAULT_PORT) === port
}
