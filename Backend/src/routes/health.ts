import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerHealthRoutes(app: Hono<AppEnv>): void {
  app.get('/health', (c) => {
    return c.json({
      ok: true,
      service: 'moviebox-backend',
      timestamp: new Date().toISOString(),
    })
  })
}
