import type { AppContext } from './context'
import { fetchWithRetry } from './fetch-retry'
import { kvGet, kvPut } from './kv-cache'

export const LOGO_TTL_HIT = 60 * 60 * 24 * 7
export const LOGO_TTL_MISS = 60 * 60 * 24
const EXT_IDS_TTL = 60 * 60 * 24 * 7
const FANART_TTL = 60 * 60 * 24 * 7
const OMDB_TTL = 60 * 60 * 24 * 7
const OMDB_MISS_TTL = 60 * 60 * 24

type FanartLogo = { url: string; lang: string; likes?: string }
export type FanartResponse = {
  hdmovielogo?: FanartLogo[]
  hdtvlogo?: FanartLogo[]
  movielogo?: FanartLogo[]
  clearlogo?: FanartLogo[]
}
export type ExternalIds = { imdb_id?: string | null; tvdb_id?: number | null }
type OmdbRating = { Source: string; Value: string }
export type OmdbResponse = {
  Response?: 'True' | 'False'
  imdbID?: string
  imdbRating?: string
  imdbVotes?: string
  Metascore?: string
  Runtime?: string
  Plot?: string
  Director?: string
  Writer?: string
  Actors?: string
  Awards?: string
  Rated?: string
  Released?: string
  Country?: string
  Language?: string
  Production?: string
  BoxOffice?: string
  Genre?: string
  Ratings?: OmdbRating[]
}

export function pickBestLogo(payload: FanartResponse): string | null {
  const buckets: (FanartLogo[] | undefined)[] = [
    payload.hdmovielogo,
    payload.hdtvlogo,
    payload.movielogo,
    payload.clearlogo,
  ]
  for (const bucket of buckets) {
    if (!bucket || bucket.length === 0) continue
    const english = bucket.filter((l) => l.lang === 'en')
    const pool = english.length > 0 ? english : bucket
    const sorted = [...pool].toSorted(
      (a, b) => (parseInt(b.likes || '0', 10) || 0) - (parseInt(a.likes || '0', 10) || 0)
    )
    if (sorted[0]?.url) return sorted[0].url
  }
  return null
}

export async function fetchExternalIds(
  c: AppContext,
  kind: 'movie' | 'tv',
  id: string
): Promise<ExternalIds | null> {
  const cacheKey = `extids:${kind}:${id}`
  const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
  if (cached) return JSON.parse(cached) as ExternalIds
  const url = `https://api.themoviedb.org/3/${kind}/${id}/external_ids`
  const response = await fetchWithRetry(url, {
    headers: { Authorization: `Bearer ${c.env.TMDB_TOKEN}` },
  })
  if (response.status === 404) {
    await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify({}), { expirationTtl: LOGO_TTL_MISS })
    return {}
  }
  if (!response.ok) return null
  const data = (await response.json()) as ExternalIds
  await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(data), { expirationTtl: EXT_IDS_TTL })
  return data
}

export function parseOmdbInt(value: string | undefined): number | null {
  if (!value || value === 'N/A') return null
  const n = parseInt(value.replace(/[, ]/g, ''), 10)
  return Number.isFinite(n) ? n : null
}

export function parseOmdbFloat(value: string | undefined): number | null {
  if (!value || value === 'N/A') return null
  const n = parseFloat(value)
  return Number.isFinite(n) ? n : null
}

export function findOmdbRating(ratings: OmdbRating[] | undefined, source: string): number | null {
  if (!ratings) return null
  const match = ratings.find((r) => r.Source.toLowerCase() === source.toLowerCase())
  if (!match) return null
  const pct = match.Value.match(/^(\d+)%/)
  if (pct) return parseInt(pct[1], 10)
  const frac = match.Value.match(/^([\d.]+)\s*\/\s*(\d+)/)
  if (!frac) return null
  const num = parseFloat(frac[1])
  const denom = parseInt(frac[2], 10)
  return denom > 0 ? Math.round((num / denom) * 100) : null
}

export function parseOmdbRuntime(runtime: string | undefined): number | null {
  if (!runtime || runtime === 'N/A') return null
  const m = runtime.match(/(\d+)/)
  return m ? parseInt(m[1], 10) : null
}

export async function fetchOmdbById(c: AppContext, imdbId: string): Promise<OmdbResponse | null> {
  if (!c.env.OMDB_API_KEY) return null
  const cacheKey = `omdb:id:${imdbId}`
  const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
  if (cached) return JSON.parse(cached) as OmdbResponse
  const url = new URL('https://www.omdbapi.com/')
  url.searchParams.set('i', imdbId)
  url.searchParams.set('apikey', c.env.OMDB_API_KEY)
  const response = await fetch(url.toString())
  if (!response.ok) return null
  const data = (await response.json()) as OmdbResponse
  await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(data), {
    expirationTtl: data.Response === 'True' ? OMDB_TTL : OMDB_MISS_TTL,
  })
  return data
}

export async function fetchOmdbByTitle(
  c: AppContext,
  title: string,
  year?: string | number | null,
  type?: 'movie' | 'series'
): Promise<OmdbResponse | null> {
  if (!c.env.OMDB_API_KEY) return null
  const cacheKey = `omdb:t:${title.trim().toLowerCase()}:${year ?? ''}:${type ?? ''}`
  const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
  if (cached) return JSON.parse(cached) as OmdbResponse
  const url = new URL('https://www.omdbapi.com/')
  url.searchParams.set('t', title)
  if (year) url.searchParams.set('y', String(year))
  if (type) url.searchParams.set('type', type)
  url.searchParams.set('apikey', c.env.OMDB_API_KEY)
  const response = await fetch(url.toString())
  if (!response.ok) return null
  const data = (await response.json()) as OmdbResponse
  await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(data), {
    expirationTtl: data.Response === 'True' ? OMDB_TTL : OMDB_MISS_TTL,
  })
  return data
}

export function proxyImage(c: AppContext, upstream: string | null | undefined): string | null {
  if (!upstream) return null
  const origin = new URL(c.req.url).origin
  if (upstream.startsWith(`${origin}/img?`)) return upstream
  return `${origin}/img?u=${encodeURIComponent(upstream)}`
}

export async function fetchFanart(
  c: AppContext,
  kind: 'movies' | 'tv',
  externalId: string | number
): Promise<FanartResponse | null> {
  const cacheKey = `fanart:${kind}:${externalId}`
  const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
  if (cached) return JSON.parse(cached) as FanartResponse
  const url = `https://webservice.fanart.tv/v3/${kind}/${externalId}?api_key=${c.env.FANART_API_KEY}`
  const response = await fetch(url)
  if (response.status === 404) {
    await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify({}), { expirationTtl: LOGO_TTL_MISS })
    return {}
  }
  if (!response.ok) return null
  const data = (await response.json()) as FanartResponse
  await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(data), { expirationTtl: FANART_TTL })
  return data
}
