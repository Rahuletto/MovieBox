import type { TorrentIndexer, TorrentSearchHit } from '../types'
import {
  decodeHtml,
  fetchHTML,
  hashFromMagnet,
  parseSizeBytes,
  resolveQualityLabel,
  searchWithQueryVariants,
} from '../utils'

function parseTorrentDownloadRows(html: string): Array<{
  title: string
  magnet: string
  seeders: number
  leechers: number
  size: string
}> {
  const rows: Array<{
    title: string
    magnet: string
    seeders: number
    leechers: number
    size: string
  }> = []

  // Parse table structure
  const rowRegex = /<tr[^>]*>([\s\S]*?)<\/tr>/gi
  let match: RegExpExecArray | null

  while ((match = rowRegex.exec(html)) !== null) {
    const row = match[1]

    // Skip header rows
    if (row.includes('<th')) continue
    if (!row.includes('magnet:')) continue

    // Extract title and magnet
    const titleMatch = row.match(/<a[^>]*>([^<]+)<\/a>/i)
    const magnetMatch = row.match(/href="(magnet:\?[^"]+)"/i)

    if (!titleMatch || !magnetMatch) continue

    // Extract cells
    const cells = row.match(/<td[^>]*>([^<]*)<\/td>/gi) || []
    let seeders = 0
    let leechers = 0
    let size = ''

    if (cells.length >= 3) {
      size = cells[1]?.replace(/<[^>]*>/g, '').trim() || ''
      seeders = parseInt(cells[cells.length - 2]?.replace(/<[^>]*>/g, '') || '0', 10)
      leechers = parseInt(cells[cells.length - 1]?.replace(/<[^>]*>/g, '') || '0', 10)
    }

    rows.push({
      title: decodeHtml(titleMatch[1].trim()),
      magnet: decodeHtml(magnetMatch[1]),
      seeders,
      leechers,
      size,
    })
  }

  return rows.slice(0, 30)
}

async function searchTorrentDownloadHost(base: string, query: string): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim())
  const searchUrl = `${base}/search.php?q=${slug}`

  try {
    const html = await fetchHTML(searchUrl)
    if (!html) return []

    const parsed = parseTorrentDownloadRows(html)
    if (!parsed.length) return []

    const hits: TorrentSearchHit[] = []
    for (const row of parsed.slice(0, 25)) {
      const hash = hashFromMagnet(row.magnet)
      if (!hash) continue

      hits.push({
        title: row.title,
        magnetURI: row.magnet,
        infoHash: hash,
        quality: resolveQualityLabel(undefined, row.title),
        sizeBytes: parseSizeBytes(row.size),
        seeders: row.seeders,
        leechers: row.leechers,
        trackerSource: 'Torrent Download',
      })
    }

    return hits
  } catch {
    return []
  }
}

export const torrentDownloadIndexer: TorrentIndexer = {
  id: 'torrentdownload',
  displayName: 'Torrent Download',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = ['https://www.torrentdownloaddb.info', 'https://torrentdownloaddb.info']

    return searchWithQueryVariants(ctx.query, ctx.year, async (query) => {
      for (const base of hosts) {
        try {
          const rows = await searchTorrentDownloadHost(base, query)
          if (rows.length) return rows
        } catch {
          // Try next host / query variant
        }
      }
      return []
    })
  },
}
