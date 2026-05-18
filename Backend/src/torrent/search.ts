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

  // 1. Run main indexers
  const mainPromise = runIndexers(ctx, enabled)

  // 2. If TV show and season is known, also run season pack search in parallel
  let seasonPromise: Promise<{ results: any[]; counts: Record<string, number>; errors: Record<string, string> }> = Promise.resolve({
    results: [],
    counts: {},
    errors: {}
  })

  if (opts.kind === 'tv' && season !== null) {
    let baseShowTitle = opts.query
    const titleMatch = opts.query.match(/^(.*?)\s+[Ss]\d{1,2}/i) ?? opts.query.match(/^(.*?)\s+\d{1,2}[xX]/i)
    if (titleMatch) {
      baseShowTitle = titleMatch[1].trim()
    }
    const seasonStr = String(season).padStart(2, '0')
    const seasonQuery = sanitizeQuery(`${baseShowTitle} S${seasonStr}`, opts.year)

    const seasonEnabled = new Set<string>()
    if (enabled.has('piratebay')) seasonEnabled.add('piratebay')
    if (enabled.has('1337x')) seasonEnabled.add('1337x')
    if (enabled.has('eztv')) seasonEnabled.add('eztv')

    if (seasonEnabled.size > 0) {
      const seasonCtx = {
        ...ctx,
        query: seasonQuery
      }
      seasonPromise = runIndexers(seasonCtx, seasonEnabled)
    }
  }

  const [mainRes, seasonRes] = await Promise.all([mainPromise, seasonPromise])

  // Merge the results, deduping by infoHash and taking the one with highest seeders
  const allResults = [...mainRes.results, ...seasonRes.results]
  const byHash = new Map<string, typeof allResults[0]>()
  const unhashed: typeof allResults[0][] = []

  for (const row of allResults) {
    const key = row.infoHash?.toLowerCase()
    if (!key) {
      unhashed.push(row)
      continue
    }
    const existing = byHash.get(key)
    if (!existing || (row.seeders ?? 0) > (existing.seeders ?? 0)) {
      byHash.set(key, row)
    }
  }

  const mergedResults = [...byHash.values(), ...unhashed].sort(
    (a, b) => (b.seeders ?? 0) - (a.seeders ?? 0)
  )

  // Combine counts and errors
  const finalCounts = { ...mainRes.counts }
  for (const key of Object.keys(seasonRes.counts)) {
    finalCounts[key] = (finalCounts[key] ?? 0) + seasonRes.counts[key]
  }
  const finalErrors = { ...mainRes.errors, ...seasonRes.errors }

  return {
    results: mergedResults,
    counts: finalCounts,
    errors: finalErrors,
    query: q,
    torrentio: {
      attempted: Boolean(ctx.imdbId),
      count: finalCounts.torrentio ?? 0,
      error: finalErrors.torrentio ?? null,
    },
    apiVersion: TORRENT_API_VERSION,
  }
}

/** @deprecated */
export async function searchTorrentIndexers(opts: Parameters<typeof searchAllTorrents>[0]) {
  const payload = await searchAllTorrents(opts)
  return { results: payload.results, counts: payload.counts, errors: payload.errors }
}
