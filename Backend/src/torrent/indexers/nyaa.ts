import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, hashFromMagnet, resolveQualityLabel } from '../utils'

interface NyaaResult {
  id: number
  name: string
  magnet: string
  torrent: string
  seeders: number
  leechers: number
  completed: number
  file_size: string
}

export const nyaaIndexer: TorrentIndexer = {
  id: 'nyaa',
  displayName: 'Nyaa',

  supports(ctx: SearchContext): boolean {
    // Nyaa is anime-focused; support all searches but mainly TV
    return ctx.query.toLowerCase().includes('anime') || ctx.kind === 'tv'
  },

  async search(ctx: SearchContext): Promise<TorrentSearchHit[]> {
    const url = `https://api.nyaa.si/?q=${encodeURIComponent(ctx.query)}&limit=50&format=json`
    const data = await fetchJSON<{ data: NyaaResult[] }>(url)

    if (!data?.data?.length) return []

    return data.data
      .slice(0, 25)
      .map((item) => {
        const hash = hashFromMagnet(item.magnet)
        if (!hash) return null

        return {
          title: item.name,
          magnetURI: item.magnet,
          infoHash: hash,
          quality: resolveQualityLabel(undefined, item.name),
          sizeBytes: parseSizeBytes(item.file_size),
          seeders: item.seeders || 0,
          leechers: item.leechers || 0,
          trackerSource: 'Nyaa',
        } satisfies TorrentSearchHit
      })
      .filter((r): r is TorrentSearchHit => r !== null)
  },
}

function parseSizeBytes(text: string): number {
  const m = text.match(/([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB)/i)
  if (!m) return 0
  const n = parseFloat(m[1])
  const unit = m[2].toUpperCase()
  if (unit.startsWith('G')) return Math.round(n * 1024 ** 3)
  if (unit.startsWith('M')) return Math.round(n * 1024 ** 2)
  if (unit.startsWith('K')) return Math.round(n * 1024)
  return 0
}
