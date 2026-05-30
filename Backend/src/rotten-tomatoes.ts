
import { kvGet, kvPut } from './kv-cache'

export type RottenTomatoesStats = {
  percentage: number
  totalReviews?: number | null
  freshCount?: number | null
  rottenCount?: number | null
  averageScore?: number | null
}

export type RottenTomatoesLookup = {
  kind: 'movie' | 'tv'
  title: string
  year?: string | null
  imdbId?: string | null
}

/** Tomatometer stats + optional Fandango/MPX HLS URL resolved from the RT page. */
export type RottenTomatoesBundle = {
  stats: RottenTomatoesStats | null
  trailerHls: string | null
}

const RT_ORIGIN = 'https://www.rottentomatoes.com'
const RT_TTL_HIT = 60 * 60 * 24 * 7 // 7 days
const RT_TTL_MISS = 60 * 60 * 24 // 1 day

const BROWSER_HEADERS: HeadersInit = {
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  Accept: 'text/html,application/xhtml+xml',
  'Accept-Language': 'en-US,en;q=0.9',
}

type CriticsScorePayload = {
  averageRating?: string
  likedCount?: number
  notLikedCount?: number
  reviewCount?: number
  ratingCount?: number
  score?: string
  scorePercent?: string
}

type RTVideoItem = {
  title?: string
  description?: string
  file?: string
}

/** Converts a title to RT's typical vanity slug (`Fight Club` → `fight_club`). */
export function titleToRottenTomatoesSlug(title: string): string {
  return title
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
}

/** Picks the best `/m/…` or `/tv/…` path from an RT search HTML page. */
export function resolveRottenTomatoesPath(
  searchHtml: string,
  lookup: RottenTomatoesLookup
): string | null {
  const prefix = lookup.kind === 'movie' ? '/m/' : '/tv/'
  const baseSlug = titleToRottenTomatoesSlug(lookup.title)
  if (!baseSlug) return null
  const preferred = `${prefix}${baseSlug}`
  const re = lookup.kind === 'movie' ? /\/m\/([a-z0-9_]+)/gi : /\/tv\/([a-z0-9_]+)/gi

  const slugs = new Set<string>()
  for (const match of searchHtml.matchAll(re)) {
    slugs.add(`${prefix}${match[1]}`)
  }
  if (slugs.size === 0) return null

  // RT search pages include many unrelated `/m/…` links (nav, carousels). Only accept
  // slugs that match the title vanity prefix — otherwise we land on the wrong film
  // (e.g. `/m/tuner` 94% instead of `/m/michael` 39%).
  const relevant = [...slugs].filter((path) => {
    const s = path.slice(prefix.length)
    return s === baseSlug || s.startsWith(`${baseSlug}_`)
  })
  if (relevant.length === 0) return null

  if (relevant.includes(preferred)) return preferred

  const y = lookup.year?.trim()
  if (y && /^\d{4}$/.test(y)) {
    const withYear = `${prefix}${baseSlug}_${y}`
    if (relevant.includes(withYear)) return withYear
  }

  if (relevant.length === 1) return relevant[0]

  relevant.sort((a, b) => a.length - b.length)
  return relevant[0] ?? null
}

/** Extracts Tomatometer stats embedded in RT movie/TV pages. */
export function parseCriticsScoreFromHtml(html: string): RottenTomatoesStats | null {
  const matches = [...html.matchAll(/"criticsScore":(\{[^}]+\})/g)]
  if (matches.length === 0) return null

  let bestPayload: CriticsScorePayload | null = null
  let bestReviewCount = -1

  for (const m of matches) {
    let payload: CriticsScorePayload
    try {
      payload = JSON.parse(m[1]) as CriticsScorePayload
    } catch {
      continue
    }
    const percentage = parseTomatometerPercent(payload)
    if (percentage === null) continue

    const rcRaw = payload.reviewCount ?? payload.ratingCount ?? 0
    const reviewCount = typeof rcRaw === 'number' ? rcRaw : 0
    // Prefer the full Tomatometer blob (highest review count). RT sometimes embeds
    // a second, slimmer duplicate — both usually match, but this avoids edge cases.
    if (reviewCount > bestReviewCount) {
      bestReviewCount = reviewCount
      bestPayload = payload
    }
  }

  if (!bestPayload) return null

  const percentage = parseTomatometerPercent(bestPayload)
  if (percentage === null) return null

  const totalReviews = bestPayload.reviewCount ?? bestPayload.ratingCount ?? null
  const freshCount = bestPayload.likedCount ?? null
  const rottenCount = bestPayload.notLikedCount ?? null
  const averageScore = parseAverageRating(bestPayload.averageRating)

  return {
    percentage,
    totalReviews,
    freshCount,
    rottenCount,
    averageScore,
  }
}

function parseTomatometerPercent(payload: CriticsScorePayload): number | null {
  if (payload.score) {
    const n = parseInt(payload.score, 10)
    if (Number.isFinite(n)) return n
  }
  if (payload.scorePercent) {
    const m = payload.scorePercent.match(/(\d+)/)
    if (m) return parseInt(m[1], 10)
  }
  return null
}

function parseAverageRating(value: string | undefined): number | null {
  if (!value) return null
  const n = parseFloat(value)
  return Number.isFinite(n) ? n : null
}

/**
 * Extracts the first MPX / thePlatform feed URL embedded in RT HTML.
 * These links 302 to Akamai HLS (`index.m3u8`) when fetched with `formats=M3U+none`.
 */
export function extractThePlatformFeedUrl(html: string): string | null {
  const normalized = html.replace(/\\u002f/gi, '/')
  const m = normalized.match(
    /https:\/\/link\.theplatform\.com\/s\/[\w-]+\/media\/[\w-]+\?[^"'\s<>]+/i
  )
  return m ? m[0] : null
}

function normalizeForMatch(value: string): string {
  return value
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
}

function titleTokens(title: string): string[] {
  return normalizeForMatch(title)
    .split(/\s+/)
    .filter((t) => t.length >= 3)
}

function extractVideosPayloadItems(html: string): RTVideoItem[] {
  const m = html.match(/<script id="videos" type="application\/json">([\s\S]*?)<\/script>/i)
  if (!m) return []
  try {
    const parsed = JSON.parse(m[1]) as unknown
    if (!Array.isArray(parsed)) return []
    return parsed.filter((v): v is RTVideoItem => !!v && typeof v === 'object')
  } catch {
    return []
  }
}

/**
 * Picks the best trailer feed from RT's videos payload for the requested title.
 * This avoids cross-title mismatches from unrelated thePlatform URLs in page HTML.
 */
export function extractBestRtVideoFeedUrl(html: string, title: string): string | null {
  const items = extractVideosPayloadItems(html)
  if (items.length === 0) return null

  const titleNorm = normalizeForMatch(title)
  const tokens = titleTokens(title)
  let bestUrl: string | null = null
  let bestScore = -Infinity

  for (const item of items) {
    const file = item.file
    if (!file || !file.includes('link.theplatform.com')) continue

    const text = `${item.title ?? ''} ${item.description ?? ''}`.trim()
    const textNorm = normalizeForMatch(text)
    let score = 0

    if (textNorm.includes('trailer')) score += 80
    if (textNorm.includes('official trailer')) score += 30
    if (textNorm.includes('teaser')) score += 15
    if (textNorm.includes('clip')) score -= 20
    if (textNorm.includes(titleNorm)) score += 60

    for (const token of tokens) {
      if (textNorm.includes(token)) score += 10
    }

    if (score > bestScore) {
      bestScore = score
      bestUrl = file
    }
  }

  return bestUrl
}

/** Follows MPX redirect to the final HLS playlist URL. */
export async function resolveThePlatformFeedToHls(feedUrl: string): Promise<string | null> {
  try {
    const u = new URL(feedUrl)
    // Ask MPX for a multi-bitrate ladder so we can explicitly pick HD variants.
    u.searchParams.set('mbr', 'true')
    u.searchParams.set('formats', 'M3U+appleHlsEncryption,M3U+none')
    const r = await fetch(u.toString(), {
      headers: BROWSER_HEADERS,
      redirect: 'follow',
      signal: AbortSignal.timeout(20_000),
    })
    if (!r.ok) return null
    const final = r.url
    if (final.includes('.m3u8')) {
      return await resolveHighestVariantHls(final)
    }
    return null
  } catch (error) {
    console.warn('[rt] thePlatform HLS resolve failed:', error)
    return null
  }
}

async function resolveHighestVariantHls(manifestURL: string): Promise<string> {
  try {
    const r = await fetch(manifestURL, {
      headers: BROWSER_HEADERS,
      redirect: 'follow',
      signal: AbortSignal.timeout(20_000),
    })
    if (!r.ok) return manifestURL
    const text = await r.text()
    if (!text.includes('#EXT-X-STREAM-INF')) return manifestURL

    const lines = text.split(/\r?\n/)
    let bestHDURL: string | null = null
    let bestHDScore = -1
    let bestFallbackURL: string | null = null
    let bestFallbackScore = -1

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]?.trim() ?? ''
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue
      const attrs = line
      const next = lines[i + 1]?.trim() ?? ''
      if (!next || next.startsWith('#')) continue

      const res = attrs.match(/RESOLUTION=(\d+)x(\d+)/i)
      const bw = attrs.match(/BANDWIDTH=(\d+)/i)
      const codecs = (attrs.match(/CODECS="([^"]+)"/i)?.[1] ?? '').toLowerCase()
      const width = res ? parseInt(res[1]!, 10) : 0
      const height = res ? parseInt(res[2]!, 10) : 0
      const pixels = width * height
      const bandwidth = bw ? parseInt(bw[1]!, 10) : 0
      const score = pixels * 10 + bandwidth
      const candidateURL = new URL(next, manifestURL).toString()
      const looksVideoCodec =
        codecs.includes('avc') ||
        codecs.includes('hvc') ||
        codecs.includes('hev') ||
        codecs.includes('vp9') ||
        codecs.includes('av01')
      const isVideoVariant = pixels > 0 || looksVideoCodec
      if (!isVideoVariant) continue

      // Prefer full HD+ even if startup takes longer; quality first for trailers.
      if (height >= 1080 || width >= 1920) {
        if (score > bestHDScore) {
          bestHDScore = score
          bestHDURL = candidateURL
        }
        continue
      }

      if (score > bestFallbackScore) {
        bestFallbackScore = score
        bestFallbackURL = candidateURL
      }
    }

    const preferredVariant = bestHDURL ?? bestFallbackURL
    if (preferredVariant) {
      // Keep returning master manifest so AVPlayer can adapt quality dynamically.
      return manifestURL
    }
    return manifestURL
  } catch {
    return manifestURL
  }
}

function isUsableRtDetailHtml(html: string): boolean {
  return parseCriticsScoreFromHtml(html) != null || extractThePlatformFeedUrl(html) != null
}

function parseCachedRtBundle(cached: string): RottenTomatoesBundle | null {
  try {
    const j = JSON.parse(cached) as unknown
    if (!j || typeof j !== 'object') return null
    const o = j as Record<string, unknown>
    // Legacy: plain stats JSON (Tomatometer only, before trailer field).
    if (typeof o.percentage === 'number') {
      return { stats: o as unknown as RottenTomatoesStats, trailerHls: null }
    }
    const stats =
      o.stats != null && typeof o.stats === 'object'
        ? (o.stats as RottenTomatoesStats)
        : null
    const trailerHls = typeof o.trailerHls === 'string' ? o.trailerHls : null
    if (!stats && !trailerHls) return null
    return { stats, trailerHls }
  } catch {
    return null
  }
}

function cacheKeyFor(lookup: RottenTomatoesLookup): string {
  const year = lookup.year?.trim() || 'unknown'
  if (lookup.imdbId) return `rt:${lookup.kind}:imdb:${lookup.imdbId}`
  const slug = titleToRottenTomatoesSlug(lookup.title)
  return `rt:${lookup.kind}:${slug}:${year}`
}

/** Canonical RT paths to try before relying on `/search` (search HTML often omits the vanity link). */
function directRottenTomatoesPaths(lookup: RottenTomatoesLookup): string[] {
  const slug = titleToRottenTomatoesSlug(lookup.title)
  if (!slug) return []
  const prefix = lookup.kind === 'movie' ? '/m/' : '/tv/'
  const paths = [`${prefix}${slug}`]
  const y = lookup.year?.trim()
  if (y && /^\d{4}$/.test(y)) {
    paths.push(`${prefix}${slug}_${y}`)
  }
  return paths
}

async function fetchHtml(url: string): Promise<string | null> {
  try {
    const response = await fetch(url, { headers: BROWSER_HEADERS, redirect: 'follow' })
    if (!response.ok) return null
    return await response.text()
  } catch (error) {
    console.warn(`[rt] fetch failed ${url}:`, error)
    return null
  }
}

/**
 * Tomatometer + optional RT-hosted trailer HLS (Fandango MPX / Akamai).
 * One KV entry per title; avoids duplicate RT HTML fetches.
 */
export async function fetchRottenTomatoesBundle(
  kv: KVNamespace,
  lookup: RottenTomatoesLookup
): Promise<RottenTomatoesBundle> {
  const title = lookup.title?.trim()
  if (!title) return { stats: null, trailerHls: null }

  const cacheKey = cacheKeyFor(lookup)
  const cached = await kvGet(kv, cacheKey)
  if (cached === '__miss__') return { stats: null, trailerHls: null }
  if (cached) {
    const parsed = parseCachedRtBundle(cached)
    if (parsed) return parsed
  }

  let html: string | null = null
  let resolvedPath: string | null = null

  for (const path of directRottenTomatoesPaths(lookup)) {
    const h = await fetchHtml(`${RT_ORIGIN}${path}`)
    if (h && isUsableRtDetailHtml(h)) {
      html = h
      resolvedPath = path
      break
    }
  }

  if (!html) {
    const searchQuery = lookup.year ? `${title} ${lookup.year}` : title
    const searchUrl = `${RT_ORIGIN}/search?search=${encodeURIComponent(searchQuery)}`
    const searchHtml = await fetchHtml(searchUrl)
    if (!searchHtml) {
      await kvPut(kv, cacheKey, '__miss__', { expirationTtl: RT_TTL_MISS })
      return { stats: null, trailerHls: null }
    }
    const path = resolveRottenTomatoesPath(searchHtml, lookup)
    if (!path) {
      await kvPut(kv, cacheKey, '__miss__', { expirationTtl: RT_TTL_MISS })
      return { stats: null, trailerHls: null }
    }
    resolvedPath = path
    html = await fetchHtml(`${RT_ORIGIN}${path}`)
  }

  if (!html || !isUsableRtDetailHtml(html)) {
    await kvPut(kv, cacheKey, '__miss__', { expirationTtl: RT_TTL_MISS })
    return { stats: null, trailerHls: null }
  }

  const stats = parseCriticsScoreFromHtml(html)
  let feed: string | null = null

  // RT `/videos` page is the most reliable source for title-specific trailer assets.
  if (resolvedPath) {
    const videosHtml = await fetchHtml(`${RT_ORIGIN}${resolvedPath}/videos`)
    if (videosHtml) {
      feed = extractBestRtVideoFeedUrl(videosHtml, title) ?? extractThePlatformFeedUrl(videosHtml)
    }
  }

  // Fallback: some pages still only expose one usable thePlatform link in detail HTML.
  if (!feed) {
    feed = extractThePlatformFeedUrl(html)
  }

  const trailerHls = feed ? await resolveThePlatformFeedToHls(feed) : null

  if (!stats && !trailerHls) {
    await kvPut(kv, cacheKey, '__miss__', { expirationTtl: RT_TTL_MISS })
    return { stats: null, trailerHls: null }
  }

  await kvPut(kv, cacheKey, JSON.stringify({ stats, trailerHls }), {
    expirationTtl: RT_TTL_HIT,
  })
  return { stats, trailerHls }
}

/** @deprecated Prefer fetchRottenTomatoesBundle when you need the trailer URL too. */
export async function fetchRottenTomatoesStats(
  kv: KVNamespace,
  lookup: RottenTomatoesLookup
): Promise<RottenTomatoesStats | null> {
  const b = await fetchRottenTomatoesBundle(kv, lookup)
  return b.stats
}

/** OMDB only exposes the Tomatometer percent — use when RT HTML lookup fails. */
export function buildRottenTomatoesStatsFromOmdb(
  percentage: number | null
): RottenTomatoesStats | null {
  if (percentage === null) return null
  return {
    percentage,
    totalReviews: null,
    freshCount: null,
    rottenCount: null,
    averageScore: null,
  }
}
