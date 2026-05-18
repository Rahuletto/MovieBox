import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { timing } from 'hono/timing'
import { logger } from 'hono/logger'
import { secureHeaders } from 'hono/secure-headers'
import {
  searchAllTorrents,
  fetchTorrentFileBytes,
  TORRENT_API_VERSION,
  INDEXER_CATALOG,
  DEFAULT_ENABLED_INDEXER_IDS,
} from './torrent'
import { assertSafeSubtitleURL, buildSubf2mURL } from './subtitle-guard'
import {
  ImageProxyQuerySchema,
  LogoRouteParamsSchema,
  SubtitleDownloadQuerySchema,
  SubtitleSearchQuerySchema,
  TitleRouteParamsSchema,
  TorrentMetadataQuerySchema,
  TorrentSearchQuerySchema,
  TrailerResolveQuerySchema,
} from './schemas'
import { parseParams, parseQuery } from './validate'
import { resolveTrailerStreamURL } from './trailer-resolve'
import { buildTMDBUpstreamURL, tmdbPathFromRequest } from './tmdb-upstream'

type Bindings = {
  TMDB_TOKEN: string
  OMDB_API_KEY?: string
  FANART_API_KEY: string
  APP_SECRET: string
  APP_ENV: string
  CORS_ORIGIN: string
  RATE_LIMIT_WINDOW_MS: string
  RATE_LIMIT_MAX_REQUESTS: string
  MOVIEBOX_CACHE: KVNamespace
}

type Variables = {
  requestId: string
  startTime: number
}

const app = new Hono<{ Bindings: Bindings; Variables: Variables }>()

// Security headers
app.use('*', secureHeaders())

// Request logging with timing
app.use('*', timing())
app.use('*', async (c, next) => {
  c.set('requestId', crypto.randomUUID())
  c.set('startTime', Date.now())
  await next()
  const duration = Date.now() - c.get('startTime')
  const status = c.res.status
  const method = c.req.method
  const path = c.req.path
  const requestId = c.get('requestId')

  if (c.env.APP_ENV === 'development') {
    console.log(`[${requestId}] ${method} ${path} -> ${status} (${duration}ms)`)
  }
})

// Configurable CORS
app.use('/api/*', async (c, next) => {
  const origin = c.env.CORS_ORIGIN || '*'
  const corsHandler = cors({
    origin: origin === '*' ? '*' : origin.split(',').map((o) => o.trim()),
    allowMethods: ['GET', 'POST', 'OPTIONS'],
    allowHeaders: ['Content-Type', 'X-MovieBox-Token'],
    maxAge: 86400,
  })
  return corsHandler(c, next)
})

// Rate limiting middleware
app.use('/api/*', async (c, next) => {
  const windowMs = parseInt(c.env.RATE_LIMIT_WINDOW_MS || '60000')
  const maxRequests = parseInt(c.env.RATE_LIMIT_MAX_REQUESTS || '100')
  const clientIp = c.req.header('CF-Connecting-IP') || c.req.header('X-Forwarded-For') || 'unknown'
  const cacheKey = `rate_limit:${clientIp}:${Math.floor(Date.now() / windowMs)}`

  const current = await c.env.MOVIEBOX_CACHE.get(cacheKey)
  const count = current ? parseInt(current) : 0

  if (count >= maxRequests) {
    return c.json(
      {
        error: 'rate_limit_exceeded',
        message: `Too many requests. Try again in ${Math.ceil(windowMs / 1000)}s.`,
        retryAfter: Math.ceil(windowMs / 1000),
      },
      429
    )
  }

  await c.env.MOVIEBOX_CACHE.put(cacheKey, String(count + 1), {
    expirationTtl: Math.ceil(windowMs / 1000),
  })

  await next()

  c.res.headers.set('X-RateLimit-Limit', String(maxRequests))
  c.res.headers.set('X-RateLimit-Remaining', String(Math.max(0, maxRequests - count - 1)))
})

// ----- Image proxy (no auth — public, host-whitelisted) ---------------------
// Cloudflare-backed image cache so logos load in ~10ms anywhere in the world
// on warm requests, with strong Cache-Control so iOS's URLCache also hits.
//
// Two cache layers:
//   1) `caches.default` — per-PoP edge cache (HTTP cache key = the request URL)
//   2) `cf: { cacheEverything, cacheTtl }` — Cloudflare object cache (global,
//      keyed by upstream URL)
// Plus aggressive Cache-Control headers so the client (URLCache on iOS) also
// caches on disk.
const ALLOWED_IMG_HOSTS = new Set(['assets.fanart.tv', 'image.tmdb.org', 'webservice.fanart.tv'])
const IMG_PROXY_TTL = 60 * 60 * 24 * 30 // 30 days
const IMG_RATE_WINDOW_MS = 60_000
const IMG_RATE_MAX = 600 // image grids fetch in bursts

app.use('/img', async (c, next) => {
  // Simple CORS for the proxy endpoint.
  c.res.headers.set('Access-Control-Allow-Origin', c.env.CORS_ORIGIN || '*')
  c.res.headers.set('Vary', 'Origin')
  await next()
})

app.use('/img', async (c, next) => {
  // Per-IP rate limit (separate bucket from /api/* so heavy image traffic
  // doesn't starve API quota and vice versa).
  const clientIp = c.req.header('CF-Connecting-IP') || c.req.header('X-Forwarded-For') || 'unknown'
  const cacheKey = `img_rate:${clientIp}:${Math.floor(Date.now() / IMG_RATE_WINDOW_MS)}`
  const current = await c.env.MOVIEBOX_CACHE.get(cacheKey)
  const count = current ? parseInt(current) : 0
  if (count >= IMG_RATE_MAX) {
    return new Response('rate limit exceeded', { status: 429 })
  }
  await c.env.MOVIEBOX_CACHE.put(cacheKey, String(count + 1), { expirationTtl: 60 })
  await next()
})

app.get('/img', async (c) => {
  const query = parseQuery(c, ImageProxyQuerySchema, c.req.query())
  if (query instanceof Response) return query

  let parsed: URL
  try {
    parsed = new URL(query.u)
  } catch {
    return new Response('invalid url', { status: 400 })
  }

  if (!ALLOWED_IMG_HOSTS.has(parsed.hostname)) {
    return new Response(`host not allowed: ${parsed.hostname}`, { status: 403 })
  }

  // Layer 1: per-PoP edge cache (Cache API).
  const cache = (globalThis as any).caches?.default as Cache | undefined
  const cacheKey = new Request(new URL(c.req.url).toString())
  if (cache) {
    const hit = await cache.match(cacheKey)
    if (hit) {
      const headers = new Headers(hit.headers)
      headers.set('X-Img-Cache', 'edge')
      return new Response(hit.body, { status: hit.status, headers })
    }
  }

  // Layer 2: Cloudflare object cache via cf-fetch options (no-op on local dev).
  const isLocal = c.req.url.includes('127.0.0.1') || c.req.url.includes('localhost')
  const init: RequestInit = isLocal
    ? {}
    : ({ cf: { cacheEverything: true, cacheTtl: IMG_PROXY_TTL } } as any)
  const upstream = await fetch(parsed.toString(), init)
  if (!upstream.ok) {
    return new Response('upstream error', { status: upstream.status })
  }

  const headers = new Headers()
  headers.set('Content-Type', upstream.headers.get('content-type') ?? 'image/png')
  headers.set('Cache-Control', `public, max-age=${IMG_PROXY_TTL}, immutable`)
  headers.set('Access-Control-Allow-Origin', c.env.CORS_ORIGIN || '*')
  headers.set('X-Img-Cache', 'miss')

  // Buffer the body so we can both return AND store in the edge cache.
  const buffer = await upstream.arrayBuffer()
  const response = new Response(buffer, { status: 200, headers })
  if (cache) {
    c.executionCtx.waitUntil(cache.put(cacheKey, response.clone()))
  }
  return response
})

// Health check (no auth required)
app.get('/health', (c) => {
  return c.json({
    ok: true,
    service: 'moviebox-backend',
    timestamp: new Date().toISOString(),
    env: c.env.APP_ENV || 'unknown',
    tmdbConfigured: Boolean(c.env.TMDB_TOKEN),
    fanartConfigured: Boolean(c.env.FANART_API_KEY),
    authConfigured: Boolean(c.env.APP_SECRET),
  })
})

// Auth middleware for API routes
app.use('/api/*', async (c, next) => {
  const token = c.req.header('X-MovieBox-Token')
  if (!c.env.APP_SECRET || token !== c.env.APP_SECRET) {
    return c.json(
      {
        error: 'unauthorized',
        message: 'Valid X-MovieBox-Token header is required.',
      },
      401
    )
  }
  await next()
})

// TMDB proxy
app.all('/api/tmdb/*', async (c) => {
  try {
    if (!c.env.TMDB_TOKEN) {
      return c.json(
        {
          error: 'misconfigured',
          message: 'TMDB_TOKEN is not set on the Worker. Run: wrangler secret put TMDB_TOKEN',
        },
        503
      )
    }

    const upstreamPath = tmdbPathFromRequest(c.req.path)
    const upstreamURL = buildTMDBUpstreamURL(c.req.url, upstreamPath)

    const headers: Record<string, string> = {
      Authorization: `Bearer ${c.env.TMDB_TOKEN}`,
      Accept: 'application/json',
    }

    const cacheKey = `tmdb:${upstreamPath}:${new URL(upstreamURL).search}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)

    if (cached) {
      const parsed = JSON.parse(cached)
      return c.json(parsed.data, {
        headers: {
          'X-Cache': 'HIT',
          'Cache-Control': parsed.cacheControl || 'public, max-age=1800',
        },
      })
    }

    const isLocal = c.req.url.includes('127.0.0.1') || c.req.url.includes('localhost')
    const fetchOptions: any = { headers }
    if (!isLocal) {
      fetchOptions.cf = {
        cacheEverything: true,
        cacheTtl: cacheTTLForTMDBPath(upstreamPath),
      }
    }
    const response = await fetch(upstreamURL, fetchOptions)

    if (!response.ok) {
      const errorBody = await response.text()
      return c.json(
        {
          error: 'upstream_error',
          message: `TMDB returned ${response.status}`,
          status: response.status,
          body: errorBody,
        },
        response.status
      )
    }

    const data = await response.json()
    const ttl = cacheTTLForTMDBPath(upstreamPath)
    await c.env.MOVIEBOX_CACHE.put(
      cacheKey,
      JSON.stringify({ data, cacheControl: `public, max-age=${ttl}` }),
      {
        expirationTtl: ttl,
      }
    )

    return c.json(data, {
      headers: {
        'X-Cache': 'MISS',
        'Cache-Control': `public, max-age=${ttl}`,
      },
    })
  } catch (error) {
    console.error('TMDB Proxy failed:', error)
    return c.json(
      {
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : 'Unknown proxy error',
      },
      502
    )
  }
})

// ----- Logo resolution (Fanart.tv) -------------------------------------------

const LOGO_TTL_HIT = 60 * 60 * 24 * 7 // 7 days for resolved logo URLs
const LOGO_TTL_MISS = 60 * 60 * 24 // 1 day for negative results (no logo / 404)
const EXT_IDS_TTL = 60 * 60 * 24 * 7 // 7 days for TMDB external_ids
const FANART_TTL = 60 * 60 * 24 * 7 // 7 days for fanart payloads

type FanartLogo = { url: string; lang: string; likes?: string }
type FanartResponse = {
  hdmovielogo?: FanartLogo[]
  hdtvlogo?: FanartLogo[]
  movielogo?: FanartLogo[]
  clearlogo?: FanartLogo[]
}
type ExternalIds = { imdb_id?: string | null; tvdb_id?: number | null }

function pickBestLogo(payload: FanartResponse): string | null {
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
      (a, b) => (parseInt(b.likes || '0') || 0) - (parseInt(a.likes || '0') || 0)
    )
    if (sorted[0]?.url) return sorted[0].url
  }
  return null
}

async function fetchExternalIds(
  c: any,
  kind: 'movie' | 'tv',
  id: string
): Promise<ExternalIds | null> {
  const cacheKey = `extids:${kind}:${id}`
  const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
  if (cached) return JSON.parse(cached) as ExternalIds

  const url = `https://api.themoviedb.org/3/${kind}/${id}/external_ids`
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${c.env.TMDB_TOKEN}` },
  })

  if (response.status === 404) {
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify({}), { expirationTtl: LOGO_TTL_MISS })
    return {}
  }
  if (!response.ok) return null

  const data = (await response.json()) as ExternalIds
  await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(data), { expirationTtl: EXT_IDS_TTL })
  return data
}

type OmdbRating = { Source: string; Value: string }
type OmdbResponse = {
  Response?: 'True' | 'False'
  Error?: string
  imdbID?: string
  imdbRating?: string // "7.8" or "N/A"
  imdbVotes?: string // "1,234,567" or "N/A"
  Metascore?: string // "74" or "N/A"
  Runtime?: string // "142 min" or "N/A"
  Plot?: string
  Title?: string
  Year?: string
  Type?: string // "movie" | "series" | "episode"
  Director?: string
  Writer?: string
  Actors?: string
  Awards?: string
  Rated?: string // "PG-13"
  Released?: string // "07 Nov 2014"
  Country?: string
  Language?: string
  Production?: string
  BoxOffice?: string
  DVD?: string
  Website?: string
  Poster?: string
  Genre?: string // "Action, Adventure, Drama"
  Ratings?: OmdbRating[]
}

function parseOmdbInt(value: string | undefined): number | null {
  if (!value || value === 'N/A') return null
  const cleaned = value.replace(/[, ]/g, '')
  const n = parseInt(cleaned, 10)
  return Number.isFinite(n) ? n : null
}

function parseOmdbFloat(value: string | undefined): number | null {
  if (!value || value === 'N/A') return null
  const n = parseFloat(value)
  return Number.isFinite(n) ? n : null
}

function findOmdbRating(ratings: OmdbRating[] | undefined, source: string): number | null {
  if (!ratings) return null
  const match = ratings.find((r) => r.Source.toLowerCase() === source.toLowerCase())
  if (!match) return null
  // Handles "91%" → 91, "7.8/10" → 78, "74/100" → 74
  const v = match.Value
  const pct = v.match(/^(\d+)%/)
  if (pct) return parseInt(pct[1], 10)
  const frac = v.match(/^([\d.]+)\s*\/\s*(\d+)/)
  if (frac) {
    const num = parseFloat(frac[1])
    const denom = parseInt(frac[2], 10)
    if (denom > 0) return Math.round((num / denom) * 100)
  }
  return null
}

const OMDB_TTL = 60 * 60 * 24 * 7 // 7 days
const OMDB_MISS_TTL = 60 * 60 * 24 // 1 day for "Not Found"

/// Fetch OMDB by imdb_id, with KV caching (positive + negative).
async function fetchOmdbById(c: any, imdbId: string): Promise<OmdbResponse | null> {
  if (!c.env.OMDB_API_KEY) return null
  const cacheKey = `omdb:id:${imdbId}`
  const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
  if (cached) return JSON.parse(cached) as OmdbResponse

  const url = new URL('https://www.omdbapi.com/')
  url.searchParams.set('i', imdbId)
  url.searchParams.set('apikey', c.env.OMDB_API_KEY)
  const response = await fetch(url.toString())
  if (!response.ok) return null

  const data = (await response.json()) as OmdbResponse
  const ttl = data.Response === 'True' ? OMDB_TTL : OMDB_MISS_TTL
  await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(data), { expirationTtl: ttl })
  return data
}

/// Fetch OMDB by title (+ optional year + type) — used to recover an imdb_id
/// when TMDB external_ids comes back empty.
async function fetchOmdbByTitle(
  c: any,
  title: string,
  year?: string | number | null,
  type?: 'movie' | 'series'
): Promise<OmdbResponse | null> {
  if (!c.env.OMDB_API_KEY) return null
  const normTitle = title.trim().toLowerCase()
  const cacheKey = `omdb:t:${normTitle}:${year ?? ''}:${type ?? ''}`
  const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
  if (cached) return JSON.parse(cached) as OmdbResponse

  const url = new URL('https://www.omdbapi.com/')
  url.searchParams.set('t', title)
  if (year) url.searchParams.set('y', String(year))
  if (type) url.searchParams.set('type', type)
  url.searchParams.set('apikey', c.env.OMDB_API_KEY)
  const response = await fetch(url.toString())
  if (!response.ok) return null

  const data = (await response.json()) as OmdbResponse
  const ttl = data.Response === 'True' ? OMDB_TTL : OMDB_MISS_TTL
  await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(data), { expirationTtl: ttl })
  return data
}

/// Rewrite an upstream image URL so it goes through our `/img` proxy.
/// The proxy edge-caches the bytes and adds long Cache-Control headers, which
/// also lets iOS's URLCache cache them aggressively on device. The function is
/// idempotent — if the URL is already proxied, it's returned unchanged.
function proxyImage(c: any, upstream: string | null | undefined): string | null {
  if (!upstream) return null
  try {
    const origin = new URL(c.req.url).origin
    if (upstream.startsWith(`${origin}/img?`)) return upstream
    return `${origin}/img?u=${encodeURIComponent(upstream)}`
  } catch {
    return upstream
  }
}

function parseOmdbRuntime(runtime: string | undefined): number | null {
  if (!runtime || runtime === 'N/A') return null
  const m = runtime.match(/(\d+)/)
  return m ? parseInt(m[1], 10) : null
}

async function fetchFanart(
  c: any,
  kind: 'movies' | 'tv',
  externalId: string | number
): Promise<FanartResponse | null> {
  const cacheKey = `fanart:${kind}:${externalId}`
  const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
  if (cached) return JSON.parse(cached) as FanartResponse

  const url = `https://webservice.fanart.tv/v3/${kind}/${externalId}?api_key=${c.env.FANART_API_KEY}`
  const response = await fetch(url)

  if (response.status === 404) {
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify({}), { expirationTtl: LOGO_TTL_MISS })
    return {}
  }
  if (!response.ok) return null

  const data = (await response.json()) as FanartResponse
  await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(data), { expirationTtl: FANART_TTL })
  return data
}

// Unified logo resolution: 1 RTT from the client.
// Server-side composes external_ids → fanart, caches every step + the final URL,
// supports movies (via imdb_id) and TV (via tvdb_id), and negative-caches misses.
app.get('/api/logo/:kind/:id', async (c) => {
  try {
    const params = parseParams(c, LogoRouteParamsSchema, c.req.param())
    if (params instanceof Response) return params
    const { kind, id } = params

    if (kind !== 'movie' && kind !== 'tv') {
      return c.json({ error: 'bad_request', message: 'kind must be movie or tv' }, 400)
    }
    if (!id || !/^\d+$/.test(id)) {
      return c.json({ error: 'bad_request', message: 'id must be a numeric TMDB id' }, 400)
    }
    if (!c.env.FANART_API_KEY) {
      return c.json({ error: 'service_unavailable', message: 'FANART_API_KEY not configured' }, 503)
    }

    const cacheKey = `logo:${kind}:${id}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
    if (cached !== null) {
      const parsed = JSON.parse(cached) as { url: string | null }
      return c.json(parsed, {
        headers: { 'X-Cache': 'HIT', 'Cache-Control': `public, max-age=${LOGO_TTL_HIT}` },
      })
    }

    const extIds = await fetchExternalIds(c, kind, id)
    if (!extIds) {
      // Transient upstream failure — do not cache.
      return c.json({ url: null }, { headers: { 'X-Cache': 'BYPASS' } })
    }

    // OMDB fallback: when TMDB has no imdb_id (very common for TV), look up by
    // the TMDB title/year via OMDB and use the recovered imdb_id for fanart.
    let imdbForFanart: string | null = extIds.imdb_id ?? null
    if (!imdbForFanart && !(kind === 'tv' && extIds.tvdb_id) && c.env.OMDB_API_KEY) {
      const titleResp = await fetch(`https://api.themoviedb.org/3/${kind}/${id}?language=en-US`, {
        headers: { Authorization: `Bearer ${c.env.TMDB_TOKEN}` },
      })
      if (titleResp.ok) {
        const t = (await titleResp.json()) as any
        const title: string | undefined = t?.title ?? t?.name
        const year = (t?.release_date ?? t?.first_air_date ?? '').toString().slice(0, 4) || null
        if (title) {
          const omdb = await fetchOmdbByTitle(c, title, year, kind === 'movie' ? 'movie' : 'series')
          if (omdb?.Response === 'True' && omdb.imdbID) {
            imdbForFanart = omdb.imdbID
          }
        }
      }
    }

    let fanart: FanartResponse | null = null
    if (kind === 'tv' && extIds.tvdb_id) {
      fanart = await fetchFanart(c, 'tv', extIds.tvdb_id)
    } else if (imdbForFanart) {
      fanart = await fetchFanart(c, kind === 'movie' ? 'movies' : 'tv', imdbForFanart)
    }

    const url = fanart ? pickBestLogo(fanart) : null
    const proxied = url ? proxyImage(c, url) : null
    const ttl = url ? LOGO_TTL_HIT : LOGO_TTL_MISS
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify({ url: proxied }), {
      expirationTtl: ttl,
    })

    return c.json(
      { url: proxied },
      { headers: { 'X-Cache': 'MISS', 'Cache-Control': `public, max-age=${ttl}` } }
    )
  } catch (error) {
    return c.json(
      {
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : 'Unknown proxy error',
      },
      502
    )
  }
})

// All torrent sources (Torrentio, YTS/ytsweb, EZTV, TPB, 1337x) — change indexers here, not in the app.
app.get('/api/torrent/search', async (c) => {
  const search = parseQuery(c, TorrentSearchQuerySchema, c.req.query())
  if (search instanceof Response) return search

  try {
    const payload = await searchAllTorrents({
      query: search.q,
      year: search.year,
      imdbId: search.imdbId,
      kind: search.kind,
      enabledIndexerIDs: search.enabled ?? search.indexers ?? null,
    })
    return c.json(payload, {
      headers: { 'Cache-Control': 'private, max-age=120' },
    })
  } catch (error) {
    return c.json(
      {
        error: 'torrent_search_failed',
        message: error instanceof Error ? error.message : 'Torrent search failed',
      },
      502
    )
  }
})

// Resolve .torrent file bytes for streaming (tries all public caches from the Worker).
app.get('/api/torrent/metadata', async (c) => {
  const meta = parseQuery(c, TorrentMetadataQuerySchema, c.req.query())
  if (meta instanceof Response) return meta

  const data = await fetchTorrentFileBytes(meta.hash)
  if (!data) {
    return c.json(
      { error: 'metadata_unavailable', message: 'No .torrent file found for this info hash.' },
      404
    )
  }

  return new Response(data, {
    headers: {
      'Content-Type': 'application/x-bittorrent',
      'Cache-Control': 'private, max-age=3600',
    },
  })
})

app.get('/api/config', (c) => {
  return c.json({
    torrentApiVersion: TORRENT_API_VERSION,
    indexers: INDEXER_CATALOG,
    defaultEnabledIndexers: DEFAULT_ENABLED_INDEXER_IDS,
    service: 'moviebox-backend',
  })
})

/** Authenticated readiness probe for the macOS app (metadata + KV + secrets). */
app.get('/api/status', async (c) => {
  let kvOk = false
  try {
    await c.env.MOVIEBOX_CACHE.put('__status_ping', '1', { expirationTtl: 60 })
    kvOk = (await c.env.MOVIEBOX_CACHE.get('__status_ping')) === '1'
  } catch {
    kvOk = false
  }

  return c.json({
    ok: Boolean(c.env.TMDB_TOKEN && c.env.APP_SECRET && kvOk),
    service: 'moviebox-backend',
    timestamp: new Date().toISOString(),
    tmdbConfigured: Boolean(c.env.TMDB_TOKEN),
    fanartConfigured: Boolean(c.env.FANART_API_KEY),
    omdbConfigured: Boolean(c.env.OMDB_API_KEY),
    kvOk,
  })
})

// Unified title bundle: detail + credits + similar + external_ids + videos + logo
// in a single client RTT, served from KV when warm.
//
// Replaces 3 client TMDB calls (`/movie/{id}`, `/credits`, `/similar`) + 1 TMDB
// external_ids call + 1 fanart call with one cached backend round-trip.
app.get('/api/title/:kind/:id', async (c) => {
  try {
    const route = parseParams(c, TitleRouteParamsSchema, c.req.param())
    if (route instanceof Response) return route
    const { kind, id } = route

    const cacheKey = `title:${kind}:${id}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
    if (cached) {
      return c.json(JSON.parse(cached), {
        headers: { 'X-Cache': 'HIT', 'Cache-Control': 'public, max-age=21600' },
      })
    }

    const url = `https://api.themoviedb.org/3/${kind}/${id}?append_to_response=credits,similar,external_ids,videos`
    const response = await fetch(url, {
      headers: { Authorization: `Bearer ${c.env.TMDB_TOKEN}` },
    })

    if (!response.ok) {
      const body = await response.text()
      return c.json(
        {
          error: 'upstream_error',
          message: `TMDB returned ${response.status}`,
          status: response.status,
          body,
        },
        response.status
      )
    }

    const detail = (await response.json()) as any

    // ----- OMDB enrichment + fallback (in parallel with fanart) ---------------
    // OMDB is used as:
    //   (a) **Fallback** when TMDB external_ids has no imdb_id → search OMDB by
    //       title+year to recover one, so fanart still works.
    //   (b) **Enrichment** — IMDB rating, IMDB votes, Metascore, Rotten Tomatoes,
    //       director, actors, awards, etc. — most of which TMDB doesn't expose
    //       at all.
    const extIds: ExternalIds = detail?.external_ids ?? {}
    const title: string | undefined = detail?.title ?? detail?.name
    const year =
      (detail?.release_date ?? detail?.first_air_date ?? '').toString().slice(0, 4) || null

    const omdbTask: Promise<OmdbResponse | null> = (async () => {
      if (!c.env.OMDB_API_KEY) return null
      if (extIds.imdb_id) return fetchOmdbById(c, extIds.imdb_id)
      if (!title) return null
      return fetchOmdbByTitle(c, title, year, kind === 'movie' ? 'movie' : 'series')
    })()

    // For TV with tvdb_id we can already start fanart in parallel; for movies we
    // need the imdb_id, which may come from OMDB. So run a two-track race:
    //   - tv+tvdb: kick off fanart now
    //   - else: wait for OMDB to learn imdb_id, then start fanart
    const fanartTask: Promise<FanartResponse | null> = (async () => {
      if (!c.env.FANART_API_KEY) return null
      if (kind === 'tv' && extIds.tvdb_id) {
        return fetchFanart(c, 'tv', extIds.tvdb_id)
      }
      if (extIds.imdb_id) {
        return fetchFanart(c, kind === 'movie' ? 'movies' : 'tv', extIds.imdb_id)
      }
      // Need OMDB to recover the imdb_id first.
      const om = await omdbTask
      if (om?.Response === 'True' && om.imdbID) {
        return fetchFanart(c, kind === 'movie' ? 'movies' : 'tv', om.imdbID)
      }
      return null
    })()

    const [omdb, fanart] = await Promise.all([omdbTask, fanartTask])
    const omdbImdbId = extIds.imdb_id ?? (omdb?.Response === 'True' ? (omdb.imdbID ?? null) : null)

    const logoUrl = fanart ? pickBestLogo(fanart) : null

    // Rewrite to go through `/img` so the client benefits from edge caching +
    // strong Cache-Control headers.
    const proxiedLogo = proxyImage(c, logoUrl)

    // Seed the standalone logo cache so /api/logo/:kind/:id is instant.
    await c.env.MOVIEBOX_CACHE.put(`logo:${kind}:${id}`, JSON.stringify({ url: proxiedLogo }), {
      expirationTtl: logoUrl ? LOGO_TTL_HIT : LOGO_TTL_MISS,
    })

    detail.moviebox_logo = proxiedLogo

    // Merge OMDB enrichment into the bundle under a dedicated namespace so the
    // raw TMDB shape stays untouched.
    if (omdb && omdb.Response === 'True') {
      const omdbRuntime = parseOmdbRuntime(omdb.Runtime)
      // All OMDB-sourced data lives under `moviebox_enrichment`. The recovered
      // `imdb_id` (when TMDB didn't have one) is merged into `external_ids` below.
      detail.moviebox_enrichment = {
        imdb_rating: parseOmdbFloat(omdb.imdbRating),
        imdb_votes: parseOmdbInt(omdb.imdbVotes),
        metascore: parseOmdbInt(omdb.Metascore),
        rotten_tomatoes: findOmdbRating(omdb.Ratings, 'Rotten Tomatoes'),
        runtime_min: omdbRuntime,
        rated: omdb.Rated && omdb.Rated !== 'N/A' ? omdb.Rated : null,
        released: omdb.Released && omdb.Released !== 'N/A' ? omdb.Released : null,
        director: omdb.Director && omdb.Director !== 'N/A' ? omdb.Director : null,
        writer: omdb.Writer && omdb.Writer !== 'N/A' ? omdb.Writer : null,
        actors: omdb.Actors && omdb.Actors !== 'N/A' ? omdb.Actors : null,
        awards: omdb.Awards && omdb.Awards !== 'N/A' ? omdb.Awards : null,
        country: omdb.Country && omdb.Country !== 'N/A' ? omdb.Country : null,
        language: omdb.Language && omdb.Language !== 'N/A' ? omdb.Language : null,
        box_office: omdb.BoxOffice && omdb.BoxOffice !== 'N/A' ? omdb.BoxOffice : null,
        production: omdb.Production && omdb.Production !== 'N/A' ? omdb.Production : null,
        genre: omdb.Genre && omdb.Genre !== 'N/A' ? omdb.Genre : null,
      }
      // Use OMDB runtime as a fallback only if TMDB didn't have one.
      if (!detail.runtime && omdbRuntime) detail.runtime = omdbRuntime
      // Use OMDB plot as a fallback only if TMDB overview is empty.
      if ((!detail.overview || !detail.overview.trim()) && omdb.Plot && omdb.Plot !== 'N/A') {
        detail.overview = omdb.Plot
      }
      // If TMDB external_ids was empty but OMDB found the id, expose it inline
      // so the iOS client picks it up via the existing external_ids path.
      if (!extIds.imdb_id && omdbImdbId) {
        detail.external_ids = { ...detail.external_ids, imdb_id: omdbImdbId }
      }
    }

    // Cache the full bundle for 6h (TMDB rarely changes for the lifetime of a session).
    const bundleTTL = 60 * 60 * 6
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(detail), { expirationTtl: bundleTTL })

    return c.json(detail, {
      headers: { 'X-Cache': 'MISS', 'Cache-Control': `public, max-age=${bundleTTL}` },
    })
  } catch (error) {
    return c.json(
      {
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : 'Unknown proxy error',
      },
      502
    )
  }
})

// Legacy raw fanart proxy — kept for backwards compatibility, with negative caching.
app.get('/api/fanart/movies/:imdbId', async (c) => {
  try {
    const imdbId = c.req.param('imdbId')
    if (!imdbId) return c.json({ error: 'bad_request', message: 'Missing imdb_id' }, 400)
    if (!c.env.FANART_API_KEY) {
      return c.json({ error: 'service_unavailable', message: 'FANART_API_KEY not configured' }, 503)
    }

    const data = await fetchFanart(c, 'movies', imdbId)
    if (data === null) {
      return c.json({ error: 'upstream_error', message: 'Fanart API error' }, 502)
    }
    return c.json(data, { headers: { 'X-Cache': 'PROXY' } })
  } catch (error) {
    return c.json(
      {
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : 'Unknown proxy error',
      },
      502
    )
  }
})

// OMDb proxy
app.get('/api/omdb', async (c) => {
  try {
    const imdbId = c.req.query('i')
    if (!imdbId) {
      return c.json({ error: 'bad_request', message: 'Missing imdb id. Use ?i=tt0000000' }, 400)
    }
    if (!c.env.OMDB_API_KEY) {
      return c.json({ error: 'service_unavailable', message: 'OMDb is not configured.' }, 503)
    }

    const url = new URL('https://www.omdbapi.com/')
    url.searchParams.set('i', imdbId)
    url.searchParams.set('apikey', c.env.OMDB_API_KEY)

    const cacheKey = `omdb:${imdbId}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)

    if (cached) {
      return c.json(JSON.parse(cached), { headers: { 'X-Cache': 'HIT' } })
    }

    const isLocal = c.req.url.includes('127.0.0.1') || c.req.url.includes('localhost')
    const fetchOptions: any = {}
    if (!isLocal) {
      fetchOptions.cf = { cacheEverything: true, cacheTtl: 60 * 60 * 24 }
    }
    const response = await fetch(url.toString(), fetchOptions)

    const data = await response.json()
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(data), { expirationTtl: 60 * 60 * 24 })

    return c.json(data, { headers: { 'X-Cache': 'MISS' } })
  } catch (error) {
    return c.json(
      {
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : 'Unknown proxy error',
      },
      502
    )
  }
})

// Subf2m subtitle search and download
app.get('/api/subtitles/search', async (c) => {
  try {
    const sub = parseQuery(c, SubtitleSearchQuerySchema, c.req.query())
    if (sub instanceof Response) return sub

    const title = sub.title
    const year = sub.year
    const language = sub.language
    const type = sub.type
    const imdbId = sub.imdb_id

    const cacheKey = `subf2m:search:${title ?? ''}:${imdbId ?? ''}:${year ?? ''}:${language}:${type}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
    if (cached) {
      return c.json(JSON.parse(cached), { headers: { 'X-Cache': 'HIT' } })
    }

    const searchQuery = imdbId ? `tt${imdbId.replace(/^tt/i, '')}` : title || ''
    const searchUrl = buildSubf2mURL(
      `/subtitles/searchbytitle?query=${encodeURIComponent(searchQuery)}&l=`
    ).toString()
    const searchHtml = await fetchWithTimeout(searchUrl)

    if (!searchHtml) {
      return c.json({ subtitles: [] })
    }

    const results = parseSubf2mSearchResults(searchHtml, year)
    if (results.length === 0) {
      return c.json({ subtitles: [] })
    }

    const subtitles: SubtitleResult[] = []
    for (const result of results.slice(0, 3)) {
      const detailUrl = buildSubf2mURL(
        `${result.path}/${normalizeLanguageCode(language)}`
      ).toString()
      const detailHtml = await fetchWithTimeout(detailUrl)
      if (detailHtml) {
        const items = parseSubf2mDetailPage(detailHtml, result.path, language)
        subtitles.push(...items)
      }
    }

    const response = { subtitles }
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(response), {
      expirationTtl: 60 * 60 * 6,
    })
    return c.json(response, { headers: { 'X-Cache': 'MISS' } })
  } catch (error) {
    return c.json(
      {
        error: 'subtitle_search_failed',
        message: error instanceof Error ? error.message : 'Unknown error',
      },
      502
    )
  }
})

app.get('/api/subtitles/download', async (c) => {
  try {
    const dl = parseQuery(c, SubtitleDownloadQuerySchema, c.req.query())
    if (dl instanceof Response) return dl
    const subtitleUrl = dl.url

    const cacheKey = `subf2m:dl:${btoa(subtitleUrl)}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey, 'arrayBuffer')
    if (cached) {
      return c.body(cached, {
        headers: {
          'Content-Type': 'application/x-subrip',
          'X-Cache': 'HIT',
        },
      })
    }

    let fullUrl: string
    try {
      fullUrl = buildSubf2mURL(subtitleUrl).toString()
    } catch {
      return c.json({ error: 'bad_request', message: 'Subtitle URL is not allowed.' }, 400)
    }
    const html = await fetchWithTimeout(fullUrl)
    if (!html) {
      return c.json({ error: 'not_found', message: 'Could not fetch subtitle page.' }, 404)
    }

    const downloadLink = extractSubf2mDownloadLink(html)
    if (!downloadLink) {
      return c.json({ error: 'not_found', message: 'No download link found.' }, 404)
    }

    let dlUrl: string
    try {
      dlUrl = downloadLink.startsWith('http')
        ? assertSafeSubtitleURL(downloadLink).toString()
        : buildSubf2mURL(downloadLink).toString()
    } catch {
      return c.json({ error: 'bad_request', message: 'Subtitle download URL is not allowed.' }, 400)
    }
    const zipResponse = await fetchWithTimeout(dlUrl, { returnType: 'arrayBuffer' })
    if (!zipResponse) {
      return c.json({ error: 'download_failed', message: 'Failed to download subtitle ZIP.' }, 502)
    }

    const srtContent = await extractSrtFromZip(zipResponse as ArrayBuffer)
    if (!srtContent) {
      return c.json({ error: 'extract_failed', message: 'No SRT file found in ZIP.' }, 502)
    }

    await c.env.MOVIEBOX_CACHE.put(cacheKey, srtContent, { expirationTtl: 60 * 60 * 24 })
    return c.body(srtContent, {
      headers: {
        'Content-Type': 'application/x-subrip',
        'X-Cache': 'MISS',
      },
    })
  } catch (error) {
    return c.json(
      {
        error: 'subtitle_download_failed',
        message: error instanceof Error ? error.message : 'Unknown error',
      },
      502
    )
  }
})

app.get('/api/trailer/resolve', async (c) => {
  try {
    const trailer = parseQuery(c, TrailerResolveQuerySchema, c.req.query())
    if (trailer instanceof Response) return trailer

    const streamURL = await resolveTrailerStreamURL(trailer.key)
    if (!streamURL) {
      return c.json(
        { error: 'trailer_unavailable', message: 'No playable stream found for this trailer key.' },
        404
      )
    }

    return c.json({ url: streamURL })
  } catch (error) {
    return c.json(
      {
        error: 'internal_error',
        message: error instanceof Error ? error.message : 'Unknown error',
      },
      500
    )
  }
})

interface Subf2mSearchResult {
  title: string
  year: string
  path: string
}

interface SubtitleResult {
  id: string
  name: string
  author: string
  language: string
  downloadUrl: string
}

function normalizeLanguageCode(lang: string): string {
  const map: Record<string, string> = {
    en: 'english',
    english: 'english',
    ar: 'arabic',
    arabic: 'arabic',
    es: 'spanish',
    spanish: 'spanish',
    fr: 'french',
    french: 'french',
    de: 'german',
    german: 'german',
    pt: 'portuguese',
    portuguese: 'portuguese',
    ru: 'russian',
    russian: 'russian',
    tr: 'turkish',
    turkish: 'turkish',
    it: 'italian',
    italian: 'italian',
    nl: 'dutch',
    dutch: 'dutch',
    ko: 'korean',
    korean: 'korean',
    ja: 'japanese',
    japanese: 'japanese',
    zh: 'chinese',
    chinese: 'chinese',
    fa: 'farsi',
    farsi: 'farsi',
    ur: 'urdu',
    urdu: 'urdu',
    hi: 'hindi',
    hindi: 'hindi',
    bn: 'bengali',
    bengali: 'bengali',
    id: 'indonesian',
    indonesian: 'indonesian',
    vi: 'vietnamese',
    vietnamese: 'vietnamese',
    th: 'thai',
    thai: 'thai',
    sv: 'swedish',
    swedish: 'swedish',
    da: 'danish',
    danish: 'danish',
    fi: 'finnish',
    finnish: 'finnish',
    no: 'norwegian',
    norwegian: 'norwegian',
    pl: 'polish',
    polish: 'polish',
    he: 'hebrew',
    hebrew: 'hebrew',
    el: 'greek',
    greek: 'greek',
    hu: 'hungarian',
    hungarian: 'hungarian',
    ro: 'romanian',
    romanian: 'romanian',
    bg: 'bulgarian',
    bulgarian: 'bulgarian',
    hr: 'croatian',
    croatian: 'croatian',
    sr: 'serbian',
    serbian: 'serbian',
    uk: 'ukrainian',
    ukrainian: 'ukrainian',
    ms: 'malay',
    malay: 'malay',
    my: 'burmese',
    burmese: 'burmese',
    ku: 'kurdish',
    kurdish: 'kurdish',
    mk: 'macedonian',
    macedonian: 'macedonian',
    ml: 'malayalam',
    malayalam: 'malayalam',
    sl: 'slovenian',
    slovenian: 'slovenian',
    si: 'sinhala',
    sinhala: 'sinhala',
  }
  return map[lang.toLowerCase()] || lang.toLowerCase()
}

function parseSubf2mSearchResults(html: string, targetYear?: string | null): Subf2mSearchResult[] {
  const results: Subf2mSearchResult[] = []

  const searchResultStart = html.indexOf('<div class="search-result">')
  if (searchResultStart === -1) return results

  const afterStart = html.substring(searchResultStart)

  const ulMatch = afterStart.match(
    /<h2 class="(exact|close|popular)">[\s\S]*?<ul>([\s\S]*?)<\/ul>/i
  )
  if (!ulMatch) return results

  const listHtml = ulMatch[2]
  const itemRegex = /<li>[\s\S]*?<a href="([^"]+)">([^<]+)<\/a>[\s\S]*?<\/li>/g
  let match

  while ((match = itemRegex.exec(listHtml)) !== null) {
    const path = match[1]
    const fullTitle = match[2].trim()

    const yearMatch = fullTitle.match(/\((\d{4})\)/)
    const year = yearMatch ? yearMatch[1] : null

    const title = fullTitle.replace(/\s*\(.*$/, '').trim()

    if (targetYear && year && year !== targetYear) continue

    results.push({ title, year: year || '', path })
  }

  return results
}

function parseSubf2mDetailPage(html: string, basePath: string, language: string): SubtitleResult[] {
  const subtitles: SubtitleResult[] = []
  const lang = normalizeLanguageCode(language)

  const itemRegex = /<li class='item\s*'>([\s\S]*?)<\/li>\s*(?=<li class='item|$)/g
  let itemMatch

  while ((itemMatch = itemRegex.exec(html)) !== null) {
    const itemHtml = itemMatch[1]

    const downloadMatch = itemHtml.match(/<a\s+class='download\s+icon-download'\s+href='([^']+)'/i)
    if (!downloadMatch) continue

    const downloadUrl = downloadMatch[1]

    const authorMatch = itemHtml.match(/<b>By\s*<a[^>]*>([^<]+)<\/a>/i)
    const author = authorMatch ? authorMatch[1].trim() : 'Unknown'

    const releaseMatch = itemHtml.match(/<ul class='scrolllist'>[\s\S]*?<li>([^<]+)<\/li>/i)
    const release = releaseMatch ? releaseMatch[1].trim() : ''

    const name = release || author

    subtitles.push({
      id: btoa(`${downloadUrl}___${lang}`),
      name,
      author,
      language: lang,
      downloadUrl,
    })
  }

  return subtitles
}

function extractSubf2mDownloadLink(html: string): string | null {
  const downloadDivMatch = html.match(/<div class="download">([\s\S]*?)<\/div>/i)
  if (!downloadDivMatch) return null

  const downloadDiv = downloadDivMatch[1]
  const linkMatch = downloadDiv.match(/<a[^>]*href="([^"]+)"/i)
  return linkMatch ? linkMatch[1] : null
}

async function extractSrtFromZip(zipBuffer: ArrayBuffer): Promise<string | null> {
  try {
    const { ZipReader, BlobReader, TextWriter, Uint8ArrayWriter } = await import('@zip.js/zip.js')

    const blob = new Blob([zipBuffer])
    const zipReader = new ZipReader(new BlobReader(blob))
    const entries = await zipReader.getEntries()

    const srtEntry =
      entries.find((e) => e.filename.toLowerCase().endsWith('.srt')) ||
      entries.find((e) => e.filename.toLowerCase().endsWith('.sub')) ||
      entries.find((e) => e.filename.toLowerCase().includes('utf')) ||
      entries[0]

    if (!srtEntry || !srtEntry.getData) return null

    const writer = srtEntry.filename.toLowerCase().endsWith('.sub')
      ? new Uint8ArrayWriter()
      : new TextWriter()

    const content = await srtEntry.getData(writer)
    await zipReader.close()

    if (typeof content === 'string') return content

    const decoder = new TextDecoder('utf-8')
    return decoder.decode(content as Uint8Array)
  } catch {
    const decoder = new TextDecoder('utf-8')
    return decoder.decode(new Uint8Array(zipBuffer))
  }
}

async function fetchWithTimeout(
  url: string,
  options: { timeout?: number; returnType?: 'text' | 'arrayBuffer' } = {}
): Promise<string | ArrayBuffer | null> {
  const { timeout = 10000, returnType = 'text' } = options

  const controller = new AbortController()
  const id = setTimeout(() => controller.abort(), timeout)

  try {
    const response = await fetch(url, { signal: controller.signal })
    clearTimeout(id)

    if (!response.ok) return null

    return returnType === 'arrayBuffer' ? await response.arrayBuffer() : await response.text()
  } catch {
    clearTimeout(id)
    return null
  }
}

// 404 handler
app.notFound((c) => {
  return c.json(
    { error: 'not_found', message: `Route ${c.req.method} ${c.req.path} not found.` },
    404
  )
})

// Error handler
app.onError((error, c) => {
  const requestId = c.get('requestId') || 'unknown'
  console.error(`[${requestId}] Unhandled error:`, error)

  return c.json(
    {
      error: 'internal_error',
      message: c.env.APP_ENV === 'development' ? error.message : 'An unexpected error occurred.',
      requestId,
    },
    500
  )
})

function cacheTTLForTMDBPath(path: string): number {
  if (path.startsWith('/genre/')) return 60 * 60 * 24
  if (path.includes('/credits') || path.includes('/images') || path.includes('/videos'))
    return 60 * 60 * 6
  if (path.startsWith('/movie/top_rated')) return 60 * 60
  if (path.startsWith('/movie/now_playing')) return 60 * 15
  if (path.startsWith('/search/')) return 60 * 30
  return 60 * 30
}

export default app
