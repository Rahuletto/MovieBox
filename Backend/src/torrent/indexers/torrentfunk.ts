import type { TorrentIndexer, TorrentSearchHit } from '../types'
import {
  decodeHtml,
  fetchHTML,
  hashFromMagnet,
  parseSizeBytes,
  resolveQualityLabel,
} from '../utils'

function parseTorrentFunkRows(html: string): Array<{
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

  // Parse table rows
  const tableRegex = /<tr[\s>]([\s\S]*?)<\/tr>/gi
  let match: RegExpExecArray | null

  while ((match = tableRegex.exec(html)) !== null) {
    const row = match[1]

    // Skip header rows
    if (row.includes('<th')) continue

    // Extract title and magnet
    const titleMatch = row.match(/<a[^>]*href="[^"]*"[^>]*>([^<]+)<\/a>/i)
    if (!titleMatch) continue

    const magnetMatch = row.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Extract stats from table cells
    const cellsMatch = row.match(/<td[^>]*>([^<]*)<\/td>/gi) || []
    let seeders = 0
    let leechers = 0
    let size = ''

    if (cellsMatch.length >= 4) {
      seeders = parseInt(cellsMatch[cellsMatch.length - 2].replace(/<[^>]*>/g, ''), 10) || 0
      leechers = parseInt(cellsMatch[cellsMatch.length - 1].replace(/<[^>]*>/g, ''), 10) || 0
    }

    const sizeMatch = row.match(/(\d+(?:\.\d+)?\s*(?:GB|MB|KB))/i)
    size = sizeMatch?.[1] ?? ''

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

async function searchTorrentFunkHost(base: string, query: string): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim()).replace(/%20/g, '+')
  const searchUrl = `${base}/search/${slug}/`

  try {
    const html = await fetchHTML(searchUrl)
    if (!html) return []

    const parsed = parseTorrentFunkRows(html)
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
        trackerSource: 'TorrentFunk',
      })
    }

    return hits
  } catch {
    return []
  }
}

export const torrentFunkIndexer: TorrentIndexer = {
  id: 'torrentfunk',
  displayName: 'TorrentFunk',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = ['https://www.torrentfunk.com', 'https://torrentfunk.org']

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchTorrentFunkHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
