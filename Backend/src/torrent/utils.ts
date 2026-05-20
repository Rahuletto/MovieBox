import type { TorrentSearchHit } from './types'

export const USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

export const DEFAULT_TRACKERS = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
]

export function magnetFor(infoHash: string, title: string): string {
  const hash = infoHash.replace(/^urn:btih:/i, '').toLowerCase()
  const trackerParams = DEFAULT_TRACKERS.map((tr) => `&tr=${encodeURIComponent(tr)}`).join('')
  return `magnet:?xt=urn:btih:${hash}&dn=${encodeURIComponent(title)}${trackerParams}`
}

export function sanitizeQuery(title: string, year?: number | null): string {
  let cleaned = title.replace(/%/g, '').replace(/\s+/g, ' ').trim()
  if (!cleaned) return title.replace(/%/g, '').trim()

  // Repair already-doubled years from older clients ("Fight Club 1999 1999").
  cleaned = cleaned.replace(/\b((?:19|20)\d{2})\s+\1\b$/i, '$1')

  if (year && year >= 1900 && year <= 2100) {
    // The macOS app sends `q` with year baked in (TorrentSearchQuery.make) plus `year=`.
    if (new RegExp(`\\b${year}\\b`).test(cleaned)) return cleaned
    return `${cleaned} ${year}`
  }
  return cleaned
}

export function normalizeImdb(raw?: string | null): string | null {
  if (!raw) return null
  let value = raw.trim()
  if (!value) return null
  if (!value.startsWith('tt')) value = `tt${value}`
  return value
}

export async function fetchJSON<T>(url: string, referer?: string): Promise<T | null> {
  const headers: Record<string, string> = { 'User-Agent': USER_AGENT, Accept: 'application/json' }
  if (referer) headers.Referer = referer
  try {
    const res = await fetch(url, { headers, cf: { cacheTtl: 300, cacheEverything: true } })
    if (!res.ok) return null
    return (await res.json()) as T
  } catch {
    return null
  }
}

export async function fetchHTML(url: string, referer?: string): Promise<string | null> {
  const headers: Record<string, string> = { 'User-Agent': USER_AGENT, Accept: 'text/html' }
  if (referer) headers.Referer = referer
  const res = await fetch(url, { headers, redirect: 'follow' })
  if (!res.ok) return null
  return await res.text()
}

export function decodeHtml(text: string): string {
  return text
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
}

export function parseSizeBytes(text: string): number {
  const m = text.match(/([\d.]+)\s*(GB|MB|KB|GiB|MiB|TB)/i)
  if (!m) return 0
  const n = parseFloat(m[1])
  const unit = m[2].toUpperCase()
  if (unit.startsWith('T')) return Math.round(n * 1024 ** 4)
  if (unit.startsWith('G')) return Math.round(n * 1024 ** 3)
  if (unit.startsWith('M')) return Math.round(n * 1024 ** 2)
  if (unit.startsWith('K')) return Math.round(n * 1024)
  return 0
}

export function hashFromMagnet(magnet: string): string | null {
  const match = magnet.match(/btih:([a-fA-F0-9]{40})/i) ?? magnet.match(/btih:([a-zA-Z0-9]+)/i)
  return match ? match[1].toLowerCase() : null
}

/** Infer display quality from API label + release title (4K / 1080p / 720p). */
export function resolveQualityLabel(label: string | undefined, title: string): string {
  const blob = `${label ?? ''} ${title}`.toLowerCase()
  if (/2160|4k|uhd/.test(blob)) return '2160p'
  if (/720/.test(blob)) return '720p'
  if (/1080/.test(blob)) return '1080p'
  if (label && /^\d{3,4}p$/i.test(label.trim())) return label.trim().toLowerCase()
  return '1080p'
}

export function mergeHits(
  merged: TorrentSearchHit[],
  seen: Set<string>,
  rows: TorrentSearchHit[]
): void {
  for (const row of rows) {
    const key = row.infoHash?.toLowerCase()
    if (key && seen.has(key)) continue
    if (key) seen.add(key)
    merged.push(row)
  }
}
