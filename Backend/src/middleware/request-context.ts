import { timing } from 'hono/timing'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerRequestContext(app: Hono<AppEnv>): void {
  app.use('*', timing())
  app.use('*', async (c, next) => {
    c.set('requestId', crypto.randomUUID())
    c.set('startTime', Date.now())
    await next()
    if (c.env.APP_ENV !== 'development') return
    const duration = Date.now() - c.get('startTime')
    console.log(
      `[${c.get('requestId')}] ${c.req.method} ${c.req.path} -> ${c.res.status} (${duration}ms)`
    )
  })
}
