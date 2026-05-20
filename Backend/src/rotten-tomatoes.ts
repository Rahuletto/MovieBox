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
  const preferred = `${prefix}${titleToRottenTomatoesSlug(lookup.title)}`
  const re = lookup.kind === 'movie' ? /\/m\/([a-z0-9_]+)/gi : /\/tv\/([a-z0-9_]+)/gi

  const slugs = new Set<string>()
  for (const match of searchHtml.matchAll(re)) {
    slugs.add(`${prefix}${match[1]}`)
  }
  if (slugs.size === 0) return null
  if (slugs.has(preferred)) return preferred

  const base = titleToRottenTomatoesSlug(lookup.title)
  const partial = [...slugs].filter((path) => path.includes(base))
  if (partial.length === 1) return partial[0]

  // Prefer exact slug, then shortest path that still contains the base slug.
  const ranked = [...slugs].sort((a, b) => {
    const aExact = a === preferred ? 0 : 1
    const bExact = b === preferred ? 0 : 1
    if (aExact !== bExact) return aExact - bExact
    return a.length - b.length
  })
  return ranked[0] ?? null
}

/** Extracts Tomatometer stats embedded in RT movie/TV pages. */
export function parseCriticsScoreFromHtml(html: string): RottenTomatoesStats | null {
  const match = html.match(/"criticsScore":(\{[^}]+\})/)
  if (!match) return null

  let payload: CriticsScorePayload
  try {
    payload = JSON.parse(match[1]) as CriticsScorePayload
  } catch {
    return null
  }

  const percentage = parseTomatometerPercent(payload)
  if (percentage === null) return null

  const totalReviews = payload.reviewCount ?? payload.ratingCount ?? null
  const freshCount = payload.likedCount ?? null
  const rottenCount = payload.notLikedCount ?? null
  const averageScore = parseAverageRating(payload.averageRating)

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

function cacheKeyFor(lookup: RottenTomatoesLookup): string {
  const year = lookup.year?.trim() || 'unknown'
  if (lookup.imdbId) return `rt:v1:${lookup.kind}:imdb:${lookup.imdbId}`
  const slug = titleToRottenTomatoesSlug(lookup.title)
  return `rt:v1:${lookup.kind}:${slug}:${year}`
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
 * Resolves Tomatometer + review breakdown from rottentomatoes.com HTML.
 * Cached in KV; safe to call on every title bundle (miss → search + detail page).
 */
export async function fetchRottenTomatoesStats(
  kv: KVNamespace,
  lookup: RottenTomatoesLookup
): Promise<RottenTomatoesStats | null> {
  const title = lookup.title?.trim()
  if (!title) return null

  const cacheKey = cacheKeyFor(lookup)
  const cached = await kvGet(kv, cacheKey)
  if (cached === '__miss__') return null
  if (cached) {
    try {
      return JSON.parse(cached) as RottenTomatoesStats
    } catch {
      /* refetch */
    }
  }

  const searchQuery = lookup.year ? `${title} ${lookup.year}` : title
  const searchUrl = `${RT_ORIGIN}/search?search=${encodeURIComponent(searchQuery)}`
  const searchHtml = await fetchHtml(searchUrl)
  if (!searchHtml) return null

  const path = resolveRottenTomatoesPath(searchHtml, lookup)
  if (!path) {
    await kvPut(kv, cacheKey, '__miss__', { expirationTtl: RT_TTL_MISS })
    return null
  }

  const detailHtml = await fetchHtml(`${RT_ORIGIN}${path}`)
  if (!detailHtml) return null

  const stats = parseCriticsScoreFromHtml(detailHtml)
  await kvPut(kv, cacheKey, stats ? JSON.stringify(stats) : '__miss__', {
    expirationTtl: stats ? RT_TTL_HIT : RT_TTL_MISS,
  })
  return stats
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
