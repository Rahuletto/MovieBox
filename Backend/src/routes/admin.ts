import { DEFAULT_ENABLED_INDEXER_IDS, INDEXER_CATALOG, TORRENT_API_VERSION } from '../torrent'
import { kvDelete, kvGet, kvList, kvPut } from '../kv-cache'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

const CACHE_PURGE_PREFIXES = [
  'title:',
  'person:',
  'rt:',
  'logo:',
  'tmdb:',
  'extids:',
  'fanart:',
  'omdb:',
  'subf2m:',
]

async function purgePrefix(kv: KVNamespace, prefix: string): Promise<number> {
  let cursor: string | undefined
  let deleted = 0
  do {
    const page = await kvList(kv, { prefix, cursor, limit: 1000 })
    if (!page) break
    for (const key of page.keys) {
      if (await kvDelete(kv, key.name)) deleted += 1
    }
    cursor = page.list_complete ? undefined : page.cursor
  } while (cursor)
  return deleted
}

export function registerAdminRoutes(app: Hono<AppEnv>): void {
  app.get('/api/config', (c) => {
    return c.json({
      torrentApiVersion: TORRENT_API_VERSION,
      indexers: INDEXER_CATALOG,
      defaultEnabledIndexers: DEFAULT_ENABLED_INDEXER_IDS,
      service: 'moviebox-backend',
    })
  })

  app.post('/api/cache/purge', async (c) => {
    const scope = (c.req.query('scope') ?? 'all').toLowerCase()

    if (scope === 'prefix') {
      const prefix = c.req.query('prefix')?.trim()
      if (!prefix) {
        return c.json({ error: 'bad_request', message: 'prefix is required for scope=prefix' }, 400)
      }
      const deleted = await purgePrefix(c.env.MOVIEBOX_CACHE, prefix)
      return c.json({ ok: true, scope: 'prefix', prefix, deleted })
    }

    if (scope !== 'all') {
      return c.json({ error: 'bad_request', message: 'scope must be all or prefix' }, 400)
    }

    let deleted = 0
    for (const prefix of CACHE_PURGE_PREFIXES) {
      deleted += await purgePrefix(c.env.MOVIEBOX_CACHE, prefix)
    }
    return c.json({ ok: true, scope: 'all', deleted, prefixes: CACHE_PURGE_PREFIXES })
  })

  app.get('/api/status', async (c) => {
    let kvOk = false
    try {
      await kvPut(c.env.MOVIEBOX_CACHE, '__status_ping', '1', { expirationTtl: 60 })
      kvOk = (await kvGet(c.env.MOVIEBOX_CACHE, '__status_ping')) === '1'
    } catch {
      kvOk = false
    }

    return c.json({
      ok: Boolean(c.env.TMDB_TOKEN && c.env.APP_SECRET && kvOk),
      service: 'moviebox-backend',
      timestamp: new Date().toISOString(),
      tmdbConfigured: Boolean(c.env.TMDB_TOKEN),
      fanartConfigured: Boolean(c.env.FANART_API_KEY),
      omdbConfigured: Boolean(c.env.OMDB_API_KEY),
      kvOk,
    })
  })
}
