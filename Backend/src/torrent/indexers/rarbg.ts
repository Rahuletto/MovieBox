import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, hashFromMagnet, magnetFor, resolveQualityLabel } from '../utils'

interface RarbgTorrent {
  title: string
  magnet_uri: string
  infohash: string
  seeders: number
  leechers: number
  size: number
}

export const rarbgIndexer: TorrentIndexer = {
  id: 'rarbg',
  displayName: 'RARBG',

  supports() {
    return true
  },

  async search(ctx): Promise<TorrentSearchHit[]> {
    // RARBG was one of the best sources - use API wrapper
    const urls = [
      `https://torrentapi.org/pubapi_v2.php?mode=search&search_string=${encodeURIComponent(ctx.query)}&sort=seeders&format=json_extended&app_id=moviebox`,
      `https://api.rarbgapi.com/pubapi_v2.php?mode=search&search_string=${encodeURIComponent(ctx.query)}&sort=seeders&format=json_extended&app_id=moviebox`,
    ]

    for (const url of urls) {
      try {
        const data = await fetchJSON<{ torrent_results?: RarbgTorrent[] }>(url)

        if (!data?.torrent_results?.length) continue

        return data.torrent_results
          .slice(0, 30)
          .map((item) => {
            const hash = item.infohash?.toLowerCase() || ''
            if (hash.length !== 40) return null

            return {
              title: item.title,
              magnetURI: item.magnet_uri || magnetFor(hash, item.title),
              infoHash: hash,
              quality: resolveQualityLabel(undefined, item.title),
              sizeBytes: item.size || 0,
              seeders: item.seeders || 0,
              leechers: item.leechers || 0,
              trackerSource: 'RARBG',
            } satisfies TorrentSearchHit
          })
          .filter((r): r is TorrentSearchHit => r !== null)
      } catch {
        continue
      }
    }

    return []
  },
}
