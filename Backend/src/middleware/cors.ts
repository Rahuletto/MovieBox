import { cors } from 'hono/cors'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerApiCors(app: Hono<AppEnv>): void {
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
}
