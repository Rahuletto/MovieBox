import { INDEXER_CATALOG } from './catalog'
import { eztvIndexer } from './indexers/eztv'
import { pirateBayIndexer } from './indexers/piratebay'
import { torrentioIndexer } from './indexers/torrentio'
import { x1337Indexer } from './indexers/x1337'
import { ytsIndexer } from './indexers/yts'
import type { SearchContext, TorrentIndexer, TorrentSearchHit } from './types'

/** All indexers — add new sites here without touching the Mac app. */
export const INDEXERS: TorrentIndexer[] = [
  torrentioIndexer,
  ytsIndexer,
  eztvIndexer,
  pirateBayIndexer,
  x1337Indexer,
]

export const INDEXER_IDS = INDEXERS.map((i) => i.id)

export { INDEXER_CATALOG, DEFAULT_ENABLED_INDEXER_IDS, parseEnabledIndexerIDs } from './catalog'

const INDEXER_TIMEOUT_MS = 25_000

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
  ])
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

  // Dedup by infoHash, keeping the row with the HIGHEST seeders.
  // This avoids the previous bug where torrentio's lower-seeded entry would
  // silently absorb a Pirate Bay / 1337x match with more seeders, making
  // those sources look like they returned nothing.
  const byHash = new Map<string, TorrentSearchHit>()
  const unhashed: TorrentSearchHit[] = []

  for (let i = 0; i < settled.length; i++) {
    const outcome = settled[i]
    const indexer = active[i]
    if (outcome.status === 'fulfilled') {
      const { id, rows } = outcome.value
      counts[id] = rows.length
      for (const row of rows) {
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
    } else {
      errors[indexer.id] = outcome.reason instanceof Error ? outcome.reason.message : String(outcome.reason)
      counts[indexer.id] = 0
    }
  }

  // Sort merged results by seeders (descending) so the most healthy releases
  // surface first regardless of which indexer returned them.
  const merged = [...byHash.values(), ...unhashed].sort(
    (a, b) => (b.seeders ?? 0) - (a.seeders ?? 0)
  )

  return { results: merged, counts, errors }
}
