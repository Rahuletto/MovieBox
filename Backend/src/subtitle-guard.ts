const ALLOWED_SUBTITLE_HOSTS = new Set(['subf2m.co', 'www.subf2m.co'])

/** CDN hosts for subtitle archives (SubDL + legacy subf2m). */
const ALLOWED_SUBTITLE_CDN_HOSTS = new Set([
  'dl.subdl.com',
  'www.dl.subdl.com',
  'isubcdn.com',
  'www.isubcdn.com',
])

const PRIVATE_IPV4_RANGES: Array<[number, number]> = [
  [0x0a000000, 0x0affffff], // 10.0.0.0/8
  [0xac100000, 0xac1fffff], // 172.16.0.0/12
  [0xc0a80000, 0xc0a8ffff], // 192.168.0.0/16
  [0x7f000000, 0x7fffffff], // 127.0.0.0/8
  [0xa9fe0000, 0xa9feffff], // 169.254.0.0/16
]

function ipv4ToInt(host: string): number | null {
  const parts = host.split('.').map((p) => Number.parseInt(p, 10))
  if (parts.length !== 4 || parts.some((p) => Number.isNaN(p) || p < 0 || p > 255)) return null
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
}

function isPrivateIPv4(host: string): boolean {
  const value = ipv4ToInt(host)
  if (value == null) return false
  return PRIVATE_IPV4_RANGES.some(([start, end]) => value >= start && value <= end)
}

export function assertSafeSubtitleURL(raw: string): URL {
  let parsed: URL
  try {
    parsed = new URL(raw)
  } catch {
    throw new Error('invalid_url')
  }

  if (parsed.protocol !== 'https:') {
    throw new Error('invalid_protocol')
  }

  const host = parsed.hostname.toLowerCase()

  if (isPrivateIPv4(host) || host === 'localhost' || host.endsWith('.local')) {
    throw new Error('private_host_blocked')
  }

  if (!ALLOWED_SUBTITLE_HOSTS.has(host)) {
    throw new Error('host_not_allowed')
  }

  return parsed
}

export function buildSubf2mURL(pathOrURL: string): URL {
  const full = pathOrURL.startsWith('http') ? pathOrURL : `https://subf2m.co${pathOrURL}`
  return assertSafeSubtitleURL(full)
}

export function assertSafeSubtitleCDNURL(raw: string): URL {
  let parsed: URL
  try {
    parsed = new URL(raw)
  } catch {
    throw new Error('invalid_url')
  }

  if (parsed.protocol !== 'https:') {
    throw new Error('invalid_protocol')
  }

  const host = parsed.hostname.toLowerCase()
  if (isPrivateIPv4(host) || host === 'localhost' || host.endsWith('.local')) {
    throw new Error('private_host_blocked')
  }

  if (!ALLOWED_SUBTITLE_CDN_HOSTS.has(host)) {
    throw new Error('host_not_allowed')
  }

  return parsed
}
