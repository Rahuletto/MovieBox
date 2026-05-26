import type { Context } from 'hono'

export type Bindings = {
  TMDB_TOKEN: string
  OMDB_API_KEY?: string
  FANART_API_KEY: string
  APP_SECRET: string
  APP_ENV: string
  CORS_ORIGIN: string
  RATE_LIMIT_WINDOW_MS: string
  RATE_LIMIT_MAX_REQUESTS: string
  RATE_LIMIT_SUBTITLE_MAX_REQUESTS?: string
  SUBDL_API_KEY?: string
  MOVIEBOX_CACHE: KVNamespace
}

export type Variables = {
  requestId: string
  startTime: number
}

export type AppContext = Context<{ Bindings: Bindings; Variables: Variables }>
