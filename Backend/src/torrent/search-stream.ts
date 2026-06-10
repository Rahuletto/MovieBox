import { parseEnabledIndexerIDs } from './catalog'
import { runIndexersStreaming } from './registry'
import { sanitizeQuery } from './utils'
import type { TorrentKind, TorrentSearchHit } from './types'
import { TORRENT_API_VERSION } from './types'

export type TorrentSearchSSEWriter = (event: string, data: Record<string, unknown>) => Promise<void>

function parseSeasonEpisode(query: string, kind: TorrentKind) {
  let season: number | null = null
  let episode: number | null = null
  if (kind === 'tv') {
    const seMatch = query.match(/[Ss](\d{1,2})[\s\-_.]*[Ee](\d{1,2})/)
    if (seMatch) {
      season = parseInt(seMatch[1], 10)
      episode = parseInt(seMatch[2], 10)
    } else {
      const altMatch = query.match(/\b(\d{1,2})[xX](\d{1,2})\b/)
      if (altMatch) {
        season = parseInt(altMatch[1], 10)
        episode = parseInt(altMatch[2], 10)
      }
    }
  }
  return { season, episode }
}

function mergeHits(...groups: TorrentSearchHit[][]): TorrentSearchHit[] {
  return groups.flat().toSorted((a, b) => (b.seeders ?? 0) - (a.seeders ?? 0))
}

/** Streams torrent search results over SSE as each indexer completes. */
export async function streamAllTorrents(
  opts: {
    query: string
    year?: number | null
    imdbId?: string | null
    kind: TorrentKind
    enabledIndexerIDs?: string | null
  },
  write: TorrentSearchSSEWriter
): Promise<void> {
  const q = sanitizeQuery(opts.query, opts.year)
  const enabled = parseEnabledIndexerIDs(opts.enabledIndexerIDs)
  const { season, episode } = parseSeasonEpisode(opts.query, opts.kind)

  const ctx = {
    query: q,
    year: opts.year ?? null,
    imdbId: opts.imdbId ?? null,
    kind: opts.kind,
    enableYTS: enabled.has('yts'),
    season,
    episode,
  }

  const allBatches: TorrentSearchHit[][] = []
  const finalCounts: Record<string, number> = {}
  const finalErrors: Record<string, string> = {}

  const emitIndexerRun = async (runCtx: typeof ctx, runEnabled: Set<string>): Promise<void> => {
    await runIndexersStreaming(runCtx, runEnabled, async (batch) => {
      finalCounts[batch.id] = batch.rows.length
      if (batch.error) {
        finalErrors[batch.id] = batch.error
      }
      const capped = batch.rows.toSorted((a, b) => (b.seeders ?? 0) - (a.seeders ?? 0)).slice(0, 40)
      if (capped.length > 0) {
        allBatches.push(capped)
      }
      await write('batch', {
        indexer: batch.id,
        results: capped,
        count: capped.length,
        error: batch.error ?? null,
        mergedCount: mergeHits(...allBatches).length,
      })
    })
  }

  const mainPromise = emitIndexerRun(ctx, enabled)

  let seasonPromise: Promise<void> = Promise.resolve()
  if (opts.kind === 'tv' && season !== null) {
    let baseShowTitle = opts.query
    const titleMatch =
      opts.query.match(/^(.*?)\s+[Ss]\d{1,2}/i) ?? opts.query.match(/^(.*?)\s+\d{1,2}[xX]/i)
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
      seasonPromise = emitIndexerRun({ ...ctx, query: seasonQuery }, seasonEnabled)
    }
  }

  await Promise.all([mainPromise, seasonPromise])

  await write('done', {
    query: q,
    counts: finalCounts,
    errors: finalErrors,
    torrentio: {
      attempted: Boolean(ctx.imdbId),
      count: finalCounts.torrentio ?? 0,
      error: finalErrors.torrentio ?? null,
    },
    apiVersion: TORRENT_API_VERSION,
    totalResults: mergeHits(...allBatches).length,
  })
}
