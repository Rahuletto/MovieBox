import { kvGet, kvPut } from '../kv-cache'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

// Soft per-IP limit: KV read-modify-write is not atomic across Workers; bursts may exceed the cap.
// Treat this as abuse throttling, not a hard quota. For strict limits, use Cloudflare Rate Limiting rules.
export function registerApiRateLimit(app: Hono<AppEnv>): void {
  app.use('/api/*', async (c, next) => {
    const windowMs = parseInt(c.env.RATE_LIMIT_WINDOW_MS || '60000')
    const isSubtitleRoute = c.req.path.startsWith('/api/subtitles/')
    const maxRequests = isSubtitleRoute
      ? parseInt(c.env.RATE_LIMIT_SUBTITLE_MAX_REQUESTS || '40')
      : parseInt(c.env.RATE_LIMIT_MAX_REQUESTS || '180')
    const clientIp = c.req.header('CF-Connecting-IP') || c.req.header('X-Forwarded-For') || 'unknown'
    const bucket = isSubtitleRoute ? 'subtitle' : 'api'
    const cacheKey = `rate_limit:${bucket}:${clientIp}:${Math.floor(Date.now() / windowMs)}`

    const current = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
    const count = current ? parseInt(current) : 0

    if (count >= maxRequests) {
      const retryAfter = Math.ceil(windowMs / 1000)
      return c.json(
        {
          error: 'rate_limit_exceeded',
          message: isSubtitleRoute
            ? `Subtitle requests are temporarily limited. Try again in ${retryAfter}s.`
            : `Too many requests. Try again in ${retryAfter}s.`,
          retryAfter,
        },
        429,
        { headers: { 'Retry-After': String(retryAfter) } }
      )
    }

    await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, String(count + 1), {
      expirationTtl: Math.ceil(windowMs / 1000),
    })

    await next()

    c.res.headers.set('X-RateLimit-Limit', String(maxRequests))
    c.res.headers.set('X-RateLimit-Remaining', String(Math.max(0, maxRequests - count - 1)))
  })
}
