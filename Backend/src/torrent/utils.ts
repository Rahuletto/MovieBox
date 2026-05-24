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

const YEAR_ONLY_TITLE = /^(19|20)\d{2}$/

/** True when `year` is already present and should not be appended again. */
export function releaseYearAlreadyInQuery(cleaned: string, year: number): boolean {
  // Titles that are only a year ("2010", "1917"): the token is the film name, not a release-year suffix.
  // Still append when the release year differs ("2010" + 1984 → "2010 1984", "1917" + 2019 → "1917 2019").
  if (YEAR_ONLY_TITLE.test(cleaned)) {
    return cleaned === String(year)
  }
  return new RegExp(`\\b${year}\\b`).test(cleaned)
}

export function sanitizeQuery(title: string, year?: number | null): string {
  let cleaned = title.replace(/%/g, '').replace(/\s+/g, ' ').trim()
  if (!cleaned) return title.replace(/%/g, '').trim()

  // Repair already-doubled years from older clients ("Fight Club 1999 1999").
  cleaned = cleaned.replace(/\b((?:19|20)\d{2})\s+\1\b$/i, '$1')

  if (year && year >= 1900 && year <= 2100) {
    // The macOS app sends `q` with year baked in (TorrentSearchQuery.make) plus `year=`.
    if (releaseYearAlreadyInQuery(cleaned, year)) return cleaned
    return `${cleaned} ${year}`
  }
  return cleaned
}

const SEARCH_STOP_WORDS = new Set([
  'the',
  'a',
  'an',
  'and',
  'or',
  'of',
  'in',
  'to',
  'for',
  'with',
  'at',
  'from',
  'by',
  'on',
  'as',
  'is',
  'it',
  'vs',
])

/** Alternate text queries — long franchise titles often index under shorter names. */
export function searchQueryVariants(query: string, year?: number | null): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  const add = (value: string) => {
    const trimmed = value.replace(/\s+/g, ' ').trim()
    const key = trimmed.toLowerCase()
    if (trimmed.length >= 4 && !seen.has(key)) {
      seen.add(key)
      out.push(trimmed)
    }
  }

  add(query)

  let base = query.replace(/\s(19|20)\d{2}$/, '').trim()
  const trailingYear = query.match(/\s((19|20)\d{2})$/)
  const resolvedYear =
    year ??
    (trailingYear ? parseInt(trailingYear[1], 10) : null)

  const colonIdx = base.indexOf(':')
  if (colonIdx > 0) {
    const afterColon = base.slice(colonIdx + 1).trim()
    if (afterColon.length >= 4) {
      add(sanitizeQuery(afterColon, resolvedYear))
      add(
        afterColon
          .replace(/\b(the|a|an|and|of|in|for|with)\b/gi, ' ')
          .replace(/\s+/g, ' ')
          .trim()
      )
    }
  }

  const deStop = base
    .replace(/\b(the|a|an|and|of|in|for|with)\b/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  if (deStop.length >= 6) add(deStop)

  const words = base
    .split(/\s+/)
    .map((w) => w.replace(/[^a-zA-Z0-9]/g, ''))
    .filter((w) => w.length > 2 && !SEARCH_STOP_WORDS.has(w.toLowerCase()))

  if (words.length >= 2) add(words.slice(-2).join(' '))
  if (words.length >= 3) add(words.slice(-3).join(' '))

  return out
}

/** Try several query strings until one returns rows (used by text indexers). */
export async function searchWithQueryVariants(
  query: string,
  year: number | null | undefined,
  searchOne: (q: string) => Promise<TorrentSearchHit[]>
): Promise<TorrentSearchHit[]> {
  for (const variant of searchQueryVariants(query, year)) {
    // eslint-disable-next-line no-await-in-loop
    const rows = await searchOne(variant)
    if (rows.length) return rows
  }
  return []
}

export function normalizeImdb(raw?: string | null): string | null {
  if (!raw) return null
  let value = raw.trim()
  if (!value) return null
  if (!value.startsWith('tt')) value = `tt${value}`
  return value
}

/** Indexer APIs are dynamic — never cache subrequests (empty/error responses were getting stuck). */
const INDEXER_FETCH_INIT: RequestInit = {
  cache: 'no-store',
  redirect: 'follow',
}

export async function fetchJSON<T>(url: string, referer?: string): Promise<T | null> {
  const headers: Record<string, string> = { 'User-Agent': USER_AGENT, Accept: 'application/json' }
  if (referer) headers.Referer = referer
  try {
    const res = await fetch(url, { ...INDEXER_FETCH_INIT, headers })
    if (!res.ok) return null
    return (await res.json()) as T
  } catch {
    return null
  }
}

export async function fetchHTML(url: string, referer?: string): Promise<string | null> {
  const headers: Record<string, string> = { 'User-Agent': USER_AGENT, Accept: 'text/html' }
  if (referer) headers.Referer = referer
  try {
    const res = await fetch(url, { ...INDEXER_FETCH_INIT, headers })
    if (!res.ok) return null
    return await res.text()
  } catch {
    return null
  }
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
