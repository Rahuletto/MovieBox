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

  // Extract S{NN}E{NN} (or "1x03"-style) from the query so TV-aware indexers
  // (e.g. torrentio's `/series/{imdb}:{s}:{e}.json`) can target the episode.
  let season: number | null = null
  let episode: number | null = null
  if (opts.kind === 'tv') {
    const seMatch = opts.query.match(/[Ss](\d{1,2})[\s\-_.]*[Ee](\d{1,2})/)
    if (seMatch) {
      season = parseInt(seMatch[1], 10)
      episode = parseInt(seMatch[2], 10)
    } else {
      const altMatch = opts.query.match(/\b(\d{1,2})[xX](\d{1,2})\b/)
      if (altMatch) {
        season = parseInt(altMatch[1], 10)
        episode = parseInt(altMatch[2], 10)
      }
    }
  }

  const ctx = {
    query: q,
    year: opts.year ?? null,
    imdbId: opts.imdbId ?? null,
    kind: opts.kind,
    enableYTS: enabled.has('yts'),
    season,
    episode,
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
