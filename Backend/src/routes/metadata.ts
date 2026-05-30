import { fetchWithRetry } from '../fetch-retry'
import { kvGet, kvPut } from '../kv-cache'
import {
  LogoRouteParamsSchema,
  PersonRouteParamsSchema,
  TitleRouteParamsSchema,
} from '../schemas'
import { enrichTitleBundle } from '../title-bundle'
import {
  LOGO_TTL_HIT,
  LOGO_TTL_MISS,
  fetchExternalIds,
  fetchFanart,
  fetchOmdbByTitle,
  pickBestLogo,
  proxyImage,
} from '../logo'
import { parseParams } from '../validate'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerMetadataRoutes(app: Hono<AppEnv>): void {
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
      const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
      if (cached !== null) {
        const parsed = JSON.parse(cached) as { url: string | null }
        return c.json(parsed, {
          headers: { 'X-Cache': 'HIT', 'Cache-Control': `public, max-age=${LOGO_TTL_HIT}` },
        })
      }

      const extIds = await fetchExternalIds(c, kind, id)
      if (!extIds) {
        return c.json({ url: null }, { headers: { 'X-Cache': 'BYPASS' } })
      }

      let imdbForFanart: string | null = extIds.imdb_id ?? null
      if (!imdbForFanart && !(kind === 'tv' && extIds.tvdb_id) && c.env.OMDB_API_KEY) {
        const titleResp = await fetchWithRetry(
          `https://api.themoviedb.org/3/${kind}/${id}?language=en-US`,
          { headers: { Authorization: `Bearer ${c.env.TMDB_TOKEN}` } }
        )
        if (titleResp.ok) {
          const tmdbTitle = (await titleResp.json()) as {
            title?: string
            name?: string
            release_date?: string
            first_air_date?: string
          }
          const title = tmdbTitle.title ?? tmdbTitle.name
          const year =
            (tmdbTitle.release_date ?? tmdbTitle.first_air_date ?? '').toString().slice(0, 4) || null
          if (title) {
            const omdb = await fetchOmdbByTitle(c, title, year, kind === 'movie' ? 'movie' : 'series')
            if (omdb?.Response === 'True' && omdb.imdbID) {
              imdbForFanart = omdb.imdbID
            }
          }
        }
      }

      let fanart = null
      if (kind === 'tv' && extIds.tvdb_id) {
        fanart = await fetchFanart(c, 'tv', extIds.tvdb_id)
      } else if (imdbForFanart) {
        fanart = await fetchFanart(c, kind === 'movie' ? 'movies' : 'tv', imdbForFanart)
      }

      const url = fanart ? pickBestLogo(fanart) : null
      const proxied = url ? proxyImage(c, url) : null
      const ttl = url ? LOGO_TTL_HIT : LOGO_TTL_MISS
      await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify({ url: proxied }), {
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

  app.get('/api/title/:kind/:id', async (c) => {
    try {
      const route = parseParams(c, TitleRouteParamsSchema, c.req.param())
      if (route instanceof Response) return route
      const { kind, id } = route

      const bypassKV = c.req.query('fresh') === '1'
      const cacheKey = `title:${kind}:${id}`
      if (!bypassKV) {
        const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
        if (cached) {
          return c.json(JSON.parse(cached), {
            headers: { 'X-Cache': 'HIT', 'Cache-Control': 'public, max-age=21600' },
          })
        }
      }

      const append =
        kind === 'movie'
          ? 'credits,similar,external_ids,videos,release_dates'
          : 'credits,similar,external_ids,videos,content_ratings'
      const url = `https://api.themoviedb.org/3/${kind}/${id}?append_to_response=${append}`
      const response = await fetchWithRetry(url, {
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

      const detail = (await response.json()) as Record<string, unknown>
      const bundle = await enrichTitleBundle(c, detail, kind, id)
      const bundleTTL = 60 * 60 * 6
      await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(bundle), {
        expirationTtl: bundleTTL,
      })

      return c.json(bundle, {
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

  app.get('/api/person/:id', async (c) => {
    try {
      const route = parseParams(c, PersonRouteParamsSchema, c.req.param())
      if (route instanceof Response) return route
      const { id } = route

      const cacheKey = `person:${id}`
      const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
      if (cached) {
        return c.json(JSON.parse(cached), {
          headers: { 'X-Cache': 'HIT', 'Cache-Control': 'public, max-age=21600' },
        })
      }

      const url = `https://api.themoviedb.org/3/person/${id}?append_to_response=combined_credits,external_ids`
      const response = await fetchWithRetry(url, {
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

      const detail = await response.json()
      const bundleTTL = 60 * 60 * 6
      await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(detail), {
        expirationTtl: bundleTTL,
      })

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
      const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
      if (cached) {
        return c.json(JSON.parse(cached), { headers: { 'X-Cache': 'HIT' } })
      }

      const isLocal = c.req.url.includes('127.0.0.1') || c.req.url.includes('localhost')
      const fetchOptions: RequestInit & { cf?: { cacheEverything: boolean; cacheTtl: number } } = {}
      if (!isLocal) {
        fetchOptions.cf = { cacheEverything: true, cacheTtl: 60 * 60 * 24 }
      }
      const response = await fetch(url.toString(), fetchOptions)
      const data = await response.json()
      await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(data), {
        expirationTtl: 60 * 60 * 24,
      })

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
}
