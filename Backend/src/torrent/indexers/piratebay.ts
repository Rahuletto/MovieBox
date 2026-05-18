import type { SearchContext, TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, magnetFor, resolveQualityLabel } from '../utils'

/** apibay.org JSON API (Torrents-Api also scrapes TPB HTML; API is lighter on Workers). */
export const pirateBayIndexer: TorrentIndexer = {
  id: 'piratebay',
  displayName: 'Pirate Bay',

  supports() {
    return true
  },

  async search(ctx) {
    const url = `https://apibay.org/q.php?q=${encodeURIComponent(ctx.query)}&cat=200`
    const rows = await fetchJSON<Array<Record<string, string>>>(url)
    if (!rows?.length) return []

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
  },
}
