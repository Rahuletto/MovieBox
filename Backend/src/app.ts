import { Hono } from 'hono'
import { secureHeaders } from 'hono/secure-headers'
import type { Bindings, Variables } from './context'
import { registerApiAuth } from './middleware/api-auth'
import { registerApiCors } from './middleware/cors'
import { registerApiRateLimit } from './middleware/rate-limit'
import { registerRequestContext } from './middleware/request-context'
import { registerAdminRoutes } from './routes/admin'
import { registerHealthRoutes } from './routes/health'
import { registerImageRoutes } from './routes/images'
import { registerMetadataRoutes } from './routes/metadata'
import { registerSubtitleRoutes } from './routes/subtitles'
import { registerTmdbRoutes } from './routes/tmdb'
import { registerTorrentRoutes } from './routes/torrent'
import { registerTrailerRoutes } from './routes/trailer'

const app = new Hono<{ Bindings: Bindings; Variables: Variables }>()

app.use('*', secureHeaders())
registerRequestContext(app)
registerApiCors(app)
registerApiRateLimit(app)
registerImageRoutes(app)
registerHealthRoutes(app)
registerApiAuth(app)
registerTmdbRoutes(app)
registerMetadataRoutes(app)
registerTorrentRoutes(app)
registerAdminRoutes(app)
registerSubtitleRoutes(app)
registerTrailerRoutes(app)

app.notFound((c) => {
  return c.json(
    { error: 'not_found', message: `Route ${c.req.method} ${c.req.path} not found.` },
    404
  )
})

app.onError((error, c) => {
  const requestId = c.get('requestId') || 'unknown'
  console.error(`[${requestId}] Unhandled error:`, error)
  return c.json(
    {
      error: 'internal_error',
      message: c.env.APP_ENV === 'development' ? error.message : 'An unexpected error occurred.',
      requestId,
    },
    500
  )
})

export default app
