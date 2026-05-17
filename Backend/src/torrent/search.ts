import { parseEnabledIndexerIDs, INDEXER_CATALOG, DEFAULT_ENABLED_INDEXER_IDS } from './catalog'
import { runIndexers, INDEXER_IDS } from './registry'
import { sanitizeQuery } from './utils'
import type { TorrentKind, TorrentSearchPayload } from './types'
import { TORRENT_API_VERSION } from './types'

export { TORRENT_API_VERSION } from './types'
export { INDEXER_IDS, INDEXER_CATALOG, DEFAULT_ENABLED_INDEXER_IDS, parseEnabledIndexerIDs } from './catalog'
export { parse1337xSearchRows } from './indexers/x1337'

export async function searchAllTorrents(opts: {
  query: string
  year?: number | null
  imdbId?: string | null
  kind: TorrentKind
  enabledIndexerIDs?: string | null
}): Promise<TorrentSearchPayload> {
  const q = sanitizeQuery(opts.query, opts.year)
  const enabled = parseEnabledIndexerIDs(opts.enabledIndexerIDs)
  const ctx = {
    query: q,
    year: opts.year ?? null,
    imdbId: opts.imdbId ?? null,
    kind: opts.kind,
    enableYTS: enabled.has('yts'),
  }

  const { results, counts, errors } = await runIndexers(ctx, enabled)

  return {
    results,
    counts,
    errors,
    query: q,
    torrentio: {
      attempted: Boolean(ctx.imdbId),
      count: counts.torrentio ?? 0,
      error: errors.torrentio ?? null,
    },
    apiVersion: TORRENT_API_VERSION,
  }
}

/** @deprecated */
export async function searchTorrentIndexers(opts: Parameters<typeof searchAllTorrents>[0]) {
  const payload = await searchAllTorrents(opts)
  return { results: payload.results, counts: payload.counts, errors: payload.errors }
}
