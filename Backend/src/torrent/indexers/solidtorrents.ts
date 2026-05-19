import type { SearchContext, TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, magnetFor, resolveQualityLabel } from '../utils'

interface SolidTorrent {
  name: string
  infohash: string
  swarm: {
    seeders: number
    leechers: number
  }
  size: number
  magnet?: string
}

export const solidTorrentsIndexer: TorrentIndexer = {
  id: 'solidtorrents',
  displayName: 'Solid Torrents',

  supports() {
    return true
  },

  async search(ctx: SearchContext): Promise<TorrentSearchHit[]> {
    const url = `https://api.solidtorrents.to/search?q=${encodeURIComponent(ctx.query)}&limit=50`

    try {
      const data = await fetchJSON<{ results: SolidTorrent[] }>(url)

      if (!data?.results?.length) return []

      return data.results
        .slice(0, 25)
        .map((item) => {
          const hash = item.infohash?.toLowerCase() || ''
          if (hash.length !== 40) return null

          return {
            title: item.name,
            magnetURI: magnetFor(hash, item.name),
            infoHash: hash,
            quality: resolveQualityLabel(undefined, item.name),
            sizeBytes: item.size || 0,
            seeders: item.swarm?.seeders || 0,
            leechers: item.swarm?.leechers || 0,
            trackerSource: 'Solid Torrents',
          } satisfies TorrentSearchHit
        })
        .filter((r): r is TorrentSearchHit => r !== null)
    } catch {
      return []
    }
  },
}
