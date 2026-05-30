import { fetchWithRetry, isLocalWorkerRequest } from '../fetch-retry'
import { buildTMDBUpstreamURL, tmdbPathFromRequest } from '../tmdb-upstream'
import { kvGet, kvPut } from '../kv-cache'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

function cacheTTLForTMDBPath(path: string): number {
  if (path.startsWith('/genre/')) return 60 * 60 * 24
  if (path.includes('/credits') || path.includes('/images') || path.includes('/videos')) {
    return 60 * 60 * 6
  }
  if (path.startsWith('/movie/top_rated')) return 60 * 60
  if (path.startsWith('/movie/now_playing')) return 60 * 15
  if (path.startsWith('/search/')) return 60 * 30
  return 60 * 30
}

export function registerTmdbRoutes(app: Hono<AppEnv>): void {
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
      const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
      if (cached) {
        const parsed = JSON.parse(cached) as { data: unknown; cacheControl?: string }
        return c.json(parsed.data, {
          headers: {
            'X-Cache': 'HIT',
            'Cache-Control': parsed.cacheControl || 'public, max-age=1800',
          },
        })
      }

      const fetchInit: RequestInit & { cf?: { cacheEverything: boolean; cacheTtl: number } } = {
        headers,
      }
      if (!isLocalWorkerRequest(c.req.url)) {
        fetchInit.cf = {
          cacheEverything: true,
          cacheTtl: cacheTTLForTMDBPath(upstreamPath),
        }
      }
      const response = await fetchWithRetry(upstreamURL, fetchInit)

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
      await kvPut(
        c.env.MOVIEBOX_CACHE,
        cacheKey,
        JSON.stringify({ data, cacheControl: `public, max-age=${ttl}` }),
        { expirationTtl: ttl }
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
}
