const BLOCKED_HOSTNAMES = new Set([
  'localhost',
  'localhost.localdomain',
  'metadata.google.internal',
  'metadata.goog',
])

function parseIPv4(hostname: string): number[] | null {
  const parts = hostname.split('.')
  if (parts.length !== 4) return null
  const octets: number[] = []
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null
    const value = Number.parseInt(part, 10)
    if (value > 255) return null
    octets.push(value)
  }
  return octets
}

function isPrivateIPv4(octets: number[]): boolean {
  const [a, b] = octets
  if (a === 0 || a === 10 || a === 127) return true
  if (a === 169 && b === 254) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  if (a === 100 && b >= 64 && b <= 127) return true
  return false
}

function isPrivateIPv6(hostname: string): boolean {
  const normalized = hostname.toLowerCase()
  if (normalized === '::1' || normalized === '::') return true
  if (normalized.startsWith('fe80:')) return true
  if (normalized.startsWith('fc') || normalized.startsWith('fd')) return true
  if (normalized.startsWith('::ffff:')) {
    const mapped = normalized.slice('::ffff:'.length)
    const v4 = parseIPv4(mapped)
    return v4 ? isPrivateIPv4(v4) : false
  }
  return false
}

/** Reject URLs that could reach loopback, RFC1918, or link-local targets via the image proxy. */
export function isUnsafeProxyTarget(url: URL): boolean {
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return true

  const hostname = url.hostname.toLowerCase()
  if (!hostname) return true
  if (BLOCKED_HOSTNAMES.has(hostname)) return true
  if (hostname.endsWith('.local') || hostname.endsWith('.internal')) return true

  const ipv4 = parseIPv4(hostname)
  if (ipv4) return isPrivateIPv4(ipv4)

  if (hostname.includes(':')) return isPrivateIPv6(hostname)

  return false
}
