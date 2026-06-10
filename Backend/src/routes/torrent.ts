import { streamSSE } from 'hono/streaming'
import { fetchTorrentFileBytes, searchAllTorrents, streamAllTorrents } from '../torrent'
import { TorrentMetadataQuerySchema, TorrentSearchQuerySchema } from '../schemas'
import { parseQuery } from '../validate'
import { kvGetBuffer, kvPut } from '../kv-cache'
import type { AppEnv } from '../types'
import type { Hono } from 'hono'

export function registerTorrentRoutes(app: Hono<AppEnv>): void {
  app.get('/api/torrent/search/stream', async (c) => {
    const search = parseQuery(c, TorrentSearchQuerySchema, c.req.query())
    if (search instanceof Response) return search

    c.header('Content-Encoding', 'identity')
    c.header('Cache-Control', 'no-cache, no-transform')
    c.header('Connection', 'keep-alive')
    c.header('X-Accel-Buffering', 'no')

    return streamSSE(c, async (stream) => {
      const write = async (event: string, data: Record<string, unknown>) => {
        await stream.writeSSE({ event, data: JSON.stringify(data) })
        await stream.sleep(0)
      }

      try {
        await write('ready', { ok: true })
        await streamAllTorrents(
          {
            query: search.q,
            year: search.year,
            imdbId: search.imdbId,
            kind: search.kind,
            enabledIndexerIDs: search.enabled ?? search.indexers ?? null,
          },
          write
        )
      } catch (error) {
        await write('error', {
          message: error instanceof Error ? error.message : 'Torrent search failed',
        })
      }
    })
  })

  app.get('/api/torrent/search', async (c) => {
    const search = parseQuery(c, TorrentSearchQuerySchema, c.req.query())
    if (search instanceof Response) return search

    try {
      const payload = await searchAllTorrents({
        query: search.q,
        year: search.year,
        imdbId: search.imdbId,
        kind: search.kind,
        enabledIndexerIDs: search.enabled ?? search.indexers ?? null,
      })
      return c.json(payload, {
        headers: {
          'Cache-Control': 'no-store, no-cache, must-revalidate',
          Pragma: 'no-cache',
        },
      })
    } catch (error) {
      return c.json(
        {
          error: 'torrent_search_failed',
          message: error instanceof Error ? error.message : 'Torrent search failed',
        },
        502
      )
    }
  })

  app.get('/api/torrent/metadata', async (c) => {
    const meta = parseQuery(c, TorrentMetadataQuerySchema, c.req.query())
    if (meta instanceof Response) return meta

    const cacheKey = `torrent:meta:${meta.hash.toLowerCase()}`
    const cached = await kvGetBuffer(c.env.MOVIEBOX_CACHE, cacheKey)
    if (cached) {
      return new Response(cached, {
        headers: {
          'Content-Type': 'application/x-bittorrent',
          'Cache-Control': 'public, max-age=604800',
          'X-Cache': 'HIT',
        },
      })
    }

    const data = await fetchTorrentFileBytes(meta.hash)
    if (!data) {
      return c.json(
        { error: 'metadata_unavailable', message: 'No .torrent file found for this info hash.' },
        404
      )
    }

    await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, data.buffer, {
      expirationTtl: 60 * 60 * 24 * 7,
    })

    return new Response(data, {
      headers: {
        'Content-Type': 'application/x-bittorrent',
        'Cache-Control': 'public, max-age=604800',
        'X-Cache': 'MISS',
      },
    })
  })
}
