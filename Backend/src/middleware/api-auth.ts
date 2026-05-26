import { isValidAppToken } from '../auth'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerApiAuth(app: Hono<AppEnv>): void {
  app.use('/api/*', async (c, next) => {
    const token = c.req.header('X-MovieBox-Token')
    if (!isValidAppToken(c.env.APP_SECRET, token ?? null)) {
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
}
