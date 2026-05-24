import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, magnetFor, resolveQualityLabel, searchWithQueryVariants } from '../utils'

async function searchPirateBayQuery(query: string): Promise<TorrentSearchHit[]> {
  const hosts = ['apibay.org', 'apibay.party', 'apibay.rocks']
  let rows: Array<Record<string, string>> | null = null
  for (const host of hosts) {
    for (const cat of ['201', '200', '0']) {
      const url = `https://${host}/q.php?q=${encodeURIComponent(query)}&cat=${cat}`
      // eslint-disable-next-line no-await-in-loop
      rows = await fetchJSON<Array<Record<string, string>>>(url)
      if (rows !== null && rows.some((row) => row.id !== '0' && row.name)) break
    }
    if (rows !== null && rows.some((row) => row.id !== '0' && row.name)) break
  }
  if (rows === null) {
    throw new Error('Pirate Bay API unreachable from backend')
  }
  if (!rows.length || rows.every((row) => row.id === '0')) return []

  return rows
    .filter((row) => row.id !== '0' && row.name)
    .map((row) => {
      const name = row.name!
      const hash = (row.info_hash ?? '').toLowerCase()
      if (hash.length !== 40) return null
      return {
        title: name,
        magnetURI: magnetFor(hash, name),
        infoHash: hash,
        quality: resolveQualityLabel(undefined, name),
        sizeBytes: Number(row.size ?? 0),
        seeders: Number(row.seeders ?? 0),
        leechers: Number(row.leechers ?? 0),
        trackerSource: 'Pirate Bay',
      } satisfies TorrentSearchHit
    })
    .filter((r): r is TorrentSearchHit => r !== null)
}

/** apibay.org JSON API (Torrents-Api also scrapes TPB HTML; API is lighter on Workers). */
export const pirateBayIndexer: TorrentIndexer = {
  id: 'piratebay',
  displayName: 'Pirate Bay',

  supports() {
    return true
  },

  async search(ctx) {
    return searchWithQueryVariants(ctx.query, ctx.year, searchPirateBayQuery)
  },
}
