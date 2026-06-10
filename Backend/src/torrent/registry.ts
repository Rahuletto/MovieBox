import { eztvIndexer } from './indexers/eztv'
import { pirateBayIndexer } from './indexers/piratebay'
import { torrentioIndexer } from './indexers/torrentio'
import { x1337Indexer } from './indexers/x1337'
import { ytsIndexer } from './indexers/yts'
import { nyaaIndexer } from './indexers/nyaa'
import { limeTorrentsIndexer } from './indexers/limetorrents'
import { torrentGalaxyIndexer } from './indexers/torrentgalaxy'
import { magnetDLIndexer } from './indexers/magnetdl'
import { solidTorrentsIndexer } from './indexers/solidtorrents'
import { rutrackerIndexer } from './indexers/rutracker'
import { kickassTorrentsIndexer } from './indexers/kickasstorrents'
import { rarbgIndexer } from './indexers/rarbg'
import { zooqleIndexer } from './indexers/zooqle'
import { torrentFunkIndexer } from './indexers/torrentfunk'
import { isohuntIndexer } from './indexers/isohunt'
import { torrentDownloadIndexer } from './indexers/torrentdownload'
import { bitsearchIndexer } from './indexers/bitsearch'
import type { SearchContext, TorrentIndexer, TorrentSearchHit } from './types'

/** All indexers — add new sites here without touching the Mac app. */
export const INDEXERS: TorrentIndexer[] = [
  torrentioIndexer,
  ytsIndexer,
  eztvIndexer,
  pirateBayIndexer,
  x1337Indexer,
  nyaaIndexer,
  limeTorrentsIndexer,
  torrentGalaxyIndexer,
  magnetDLIndexer,
  solidTorrentsIndexer,
  rutrackerIndexer,
  kickassTorrentsIndexer,
  rarbgIndexer,
  zooqleIndexer,
  torrentFunkIndexer,
  isohuntIndexer,
  torrentDownloadIndexer,
  bitsearchIndexer,
]

export const INDEXER_IDS = INDEXERS.map((i) => i.id)

export { INDEXER_CATALOG, DEFAULT_ENABLED_INDEXER_IDS, parseEnabledIndexerIDs } from './catalog'

const INDEXER_TIMEOUT_MS = 15_000

function tagIndexerRows(rows: TorrentSearchHit[], indexerId: string): TorrentSearchHit[] {
  return rows.map((row) => ({ ...row, indexerId }))
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
  ])
}

/** Run indexers in parallel; emit each indexer's outcome as it completes (SSE-friendly). */
export async function runIndexersStreaming(
  ctx: SearchContext,
  enabledIds: Set<string>,
  onBatch: (batch: { id: string; rows: TorrentSearchHit[]; error?: string }) => Promise<void>
): Promise<{
  results: TorrentSearchHit[]
  counts: Record<string, number>
  errors: Record<string, string>
}> {
  const active = INDEXERS.filter((i) => enabledIds.has(i.id) && i.supports(ctx))
  const counts: Record<string, number> = {}
  const errors: Record<string, string> = {}

  const allRows: TorrentSearchHit[] = []

  await Promise.allSettled(
    active.map(async (indexer) => {
      try {
        const rows = await withTimeout(indexer.search(ctx), INDEXER_TIMEOUT_MS)
        const tagged = tagIndexerRows(rows, indexer.id)
        counts[indexer.id] = tagged.length
        allRows.push(...tagged)
        await onBatch({ id: indexer.id, rows: tagged })
      } catch (reason) {
        const message = reason instanceof Error ? reason.message : String(reason)
        errors[indexer.id] = message
        counts[indexer.id] = 0
        await onBatch({ id: indexer.id, rows: [], error: message })
      }
    })
  )

  const merged = allRows.toSorted((a, b) => (b.seeders ?? 0) - (a.seeders ?? 0))

  return { results: merged, counts, errors }
}

/** Run indexers in parallel (Torrents-Api COMBO-style Promise.allSettled). */
export async function runIndexers(
  ctx: SearchContext,
  enabledIds: Set<string>
): Promise<{
  results: TorrentSearchHit[]
  counts: Record<string, number>
  errors: Record<string, string>
}> {
  const active = INDEXERS.filter((i) => enabledIds.has(i.id) && i.supports(ctx))
  const counts: Record<string, number> = {}
  const errors: Record<string, string> = {}

  const settled = await Promise.allSettled(
    active.map(async (indexer) => {
      const rows = await withTimeout(indexer.search(ctx), INDEXER_TIMEOUT_MS)
      return { id: indexer.id, rows }
    })
  )

  const allRows: TorrentSearchHit[] = []

  for (let i = 0; i < settled.length; i++) {
    const outcome = settled[i]
    const indexer = active[i]
    if (outcome.status === 'fulfilled') {
      const { id, rows } = outcome.value
      const tagged = tagIndexerRows(rows, id)
      counts[id] = tagged.length
      allRows.push(...tagged)
    } else {
      errors[indexer.id] =
        outcome.reason instanceof Error ? outcome.reason.message : String(outcome.reason)
      counts[indexer.id] = 0
    }
  }

  const merged = allRows.toSorted((a, b) => (b.seeders ?? 0) - (a.seeders ?? 0))

  return { results: merged, counts, errors }
}
