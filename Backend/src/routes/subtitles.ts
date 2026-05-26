import { searchSubdlSubtitles, SubdlUpstreamError } from '../subdl'
import { acquireSubdlSearchSlot, SubdlQuotaExceededError } from '../subdl-quota'
import { SubtitleDownloadQuerySchema, SubtitleSearchQuerySchema } from '../schemas'
import { searchSubf2mSubtitles, type SubtitleResult } from '../subf2m'
import { parseQuery } from '../validate'
import { kvGet, kvGetBuffer, kvPut } from '../kv-cache'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerSubtitleRoutes(app: Hono<AppEnv>): void {
  app.get('/api/subtitles/search', async (c) => {
    try {
      const sub = parseQuery(c, SubtitleSearchQuerySchema, c.req.query())
      if (sub instanceof Response) return sub

      const apiKey = c.env.SUBDL_API_KEY?.trim()
      if (!apiKey) {
        return c.json(
          {
            error: 'misconfigured',
            message: 'SUBDL_API_KEY is not set on the Worker. Run: wrangler secret put SUBDL_API_KEY',
          },
          503
        )
      }

      const cacheKey = `subdl:v2:search:${sub.title ?? ''}:${sub.imdb_id ?? ''}:${sub.tmdb_id ?? ''}:${sub.year ?? ''}:${sub.language}:${sub.type}:${sub.season_number ?? ''}:${sub.episode_number ?? ''}`
      const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
      if (cached) {
        return c.json(JSON.parse(cached), {
          headers: { 'X-Cache': 'HIT', 'X-Subtitle-Provider': 'subdl' },
        })
      }

      const quota = await acquireSubdlSearchSlot(c.env.MOVIEBOX_CACHE)
      if (!quota.allowed) {
        return c.json(
          {
            error: 'subtitle_quota_exceeded',
            message: 'Subtitle search quota reached. Cached results still work; try again in an hour.',
            retryAfter: 3600,
          },
          429,
          { headers: { 'Retry-After': '3600', 'X-Subtitle-Provider': 'subdl' } }
        )
      }

      let subtitles: SubtitleResult[] = []
      let provider = 'subdl'
      let subdlFailed = false

      try {
        subtitles = await searchSubdlSubtitles({
          apiKey,
          title: sub.title ?? null,
          year: sub.year,
          language: sub.language,
          type: sub.type,
          imdbId: sub.imdb_id ?? null,
          tmdbId: sub.tmdb_id,
          seasonNumber: sub.season_number,
          episodeNumber: sub.episode_number,
        })
      } catch (error) {
        if (error instanceof SubdlUpstreamError && error.status === 429) {
          return c.json(
            {
              error: 'subtitle_rate_limited',
              message: 'SubDL rate limit hit. Try again shortly.',
              retryAfter: 120,
            },
            429,
            { headers: { 'Retry-After': '120', 'X-Subtitle-Provider': 'subdl' } }
          )
        }
        subdlFailed = true
        subtitles = []
        console.warn(
          '[subtitles] SubDL search failed, using subf2m fallback:',
          error instanceof Error ? error.message : error
        )
      }

      if (subtitles.length === 0) {
        try {
          subtitles = await searchSubf2mSubtitles({
            title: sub.title ?? null,
            year: sub.year,
            language: sub.language,
            imdbId: sub.imdb_id ?? null,
          })
          if (subtitles.length > 0) {
            provider = 'subf2m'
          } else if (subdlFailed) {
            console.warn('[subtitles] SubDL and subf2m both returned no results')
          }
        } catch (fallbackError) {
          console.error('[subtitles] subf2m fallback error:', fallbackError)
          return c.json(
            {
              error: 'subtitle_search_failed',
              message:
                fallbackError instanceof Error
                  ? fallbackError.message
                  : 'Subtitle providers are temporarily unavailable.',
            },
            502
          )
        }
      }

      const response = { subtitles }
      const ttl = subtitles.length > 0 ? 60 * 60 * 24 : 60 * 60 * 2
      await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(response), {
        expirationTtl: ttl,
      })

      return c.json(response, {
        headers: {
          'X-Cache': 'MISS',
          'X-Subtitle-Provider': provider,
          'X-Subdl-Quota-Remaining': String(quota.remaining),
        },
      })
    } catch (error) {
      if (error instanceof SubdlQuotaExceededError) {
        return c.json(
          {
            error: 'subtitle_quota_exceeded',
            message: error.message,
            retryAfter: 3600,
          },
          429,
          { headers: { 'Retry-After': '3600' } }
        )
      }
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

      const cacheKey = `sub:dl:${btoa(dl.url)}`
      const cached = await kvGetBuffer(c.env.MOVIEBOX_CACHE, cacheKey)
      if (cached) {
        return c.body(cached, {
          headers: {
            'Content-Type': 'application/x-subrip',
            'X-Cache': 'HIT',
          },
        })
      }

      const isSubf2mPath = dl.url.startsWith('/subtitles/') || dl.url.includes('subf2m.co')
      const isSubdlCDNPath =
        dl.url.includes('dl.subdl.com') ||
        dl.url.includes('isubcdn.com') ||
        dl.url.startsWith('/subtitle/')

      if (isSubf2mPath || isSubdlCDNPath) {
        const hint = isSubf2mPath
          ? 'Subf2m CDN blocked the worker; the Mac app downloads these tracks directly.'
          : 'SubDL CDN blocked the worker; the Mac app downloads these tracks directly.'
        return c.json({ error: 'client_download_required', message: hint }, 400)
      }

      return c.json({ error: 'bad_request', message: 'Unsupported subtitle download URL.' }, 400)
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
}
