import { TrailerResolveQuerySchema } from '../schemas'
import { resolveTrailerStreamURL } from '../trailer-resolve'
import { parseQuery } from '../validate'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerTrailerRoutes(app: Hono<AppEnv>): void {
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
}
