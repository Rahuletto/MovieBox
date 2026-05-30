import { consumeKvRateLimit } from '../kv-rate-limit'
import { ImageProxyQuerySchema } from '../schemas'
import { isUnsafeProxyTarget } from '../url-safety'
import { parseQuery } from '../validate'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

const ALLOWED_IMG_HOSTS = new Set(['assets.fanart.tv', 'image.tmdb.org', 'webservice.fanart.tv'])
const IMG_PROXY_TTL = 60 * 60 * 24 * 30
const IMG_RATE_WINDOW_MS = 60_000
const IMG_RATE_MAX = 600

export function registerImageRoutes(app: Hono<AppEnv>): void {
  app.use('/img', async (c, next) => {
    c.res.headers.set('Access-Control-Allow-Origin', c.env.CORS_ORIGIN || '*')
    c.res.headers.set('Vary', 'Origin')
    await next()
  })

  app.use('/img', async (c, next) => {
    const clientIp = c.req.header('CF-Connecting-IP') || c.req.header('X-Forwarded-For') || 'unknown'
    const cacheKey = `img_rate:${clientIp}:${Math.floor(Date.now() / IMG_RATE_WINDOW_MS)}`
    const { allowed } = await consumeKvRateLimit(c.env.MOVIEBOX_CACHE, cacheKey, IMG_RATE_MAX, 60)
    if (!allowed) {
      return new Response('rate limit exceeded', { status: 429 })
    }
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

    if (isUnsafeProxyTarget(parsed)) {
      return new Response('url not allowed', { status: 403 })
    }

    if (!ALLOWED_IMG_HOSTS.has(parsed.hostname)) {
      return new Response(`host not allowed: ${parsed.hostname}`, { status: 403 })
    }

    const cache = globalThis.caches?.default
    const cacheKey = new Request(new URL(c.req.url).toString())
    if (cache) {
      const hit = await cache.match(cacheKey)
      if (hit) {
        const headers = new Headers(hit.headers)
        headers.set('X-Img-Cache', 'edge')
        return new Response(hit.body, { status: hit.status, headers })
      }
    }

    const isLocal = c.req.url.includes('127.0.0.1') || c.req.url.includes('localhost')
    const init: RequestInit & { cf?: { cacheEverything: boolean; cacheTtl: number } } = isLocal
      ? {}
      : { cf: { cacheEverything: true, cacheTtl: IMG_PROXY_TTL } }
    const upstream = await fetch(parsed.toString(), init)
    if (!upstream.ok) {
      return new Response('upstream error', { status: upstream.status })
    }

    const headers = new Headers()
    headers.set('Content-Type', upstream.headers.get('content-type') ?? 'image/png')
    headers.set('Cache-Control', `public, max-age=${IMG_PROXY_TTL}, immutable`)
    headers.set('Access-Control-Allow-Origin', c.env.CORS_ORIGIN || '*')
    headers.set('X-Img-Cache', 'miss')

    const buffer = await upstream.arrayBuffer()
    const response = new Response(buffer, { status: 200, headers })
    if (cache) {
      c.executionCtx.waitUntil(cache.put(cacheKey, response.clone()))
    }
    return response
  })
}
