import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, hashFromMagnet, parseSizeBytes, resolveQualityLabel } from '../utils'

function parseIsohuntRows(html: string): Array<{
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

  // IsoHunt uses div-based layout
  const itemRegex = /<div[^>]*class="[^"]*torrent[^"]*"[^>]*>([\s\S]*?)<\/div>/gi
  let match: RegExpExecArray | null

  while ((match = itemRegex.exec(html)) !== null) {
    const item = match[1]

    // Extract title
    const titleMatch = item.match(/<a[^>]*href="[^"]*"[^>]*>([^<]+)<\/a>/i) ||
      item.match(/<span[^>]*class="[^"]*title[^"]*"[^>]*>([^<]+)<\/span>/i)
    if (!titleMatch) continue

    // Extract magnet
    const magnetMatch = item.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Extract seeders/leechers
    const seedMatch = item.match(/seeders?[:\s]*(\d+)/i)
    const leechMatch = item.match(/leechers?[:\s]*(\d+)/i)

    // Extract size
    const sizeMatch = item.match(/(\d+(?:\.\d+)?\s*(?:GB|MB|KB))/i)

    rows.push({
      title: decodeHtml(titleMatch[1].trim()),
      magnet: decodeHtml(magnetMatch[1]),
      seeders: seedMatch ? parseInt(seedMatch[1], 10) : 0,
      leechers: leechMatch ? parseInt(leechMatch[1], 10) : 0,
      size: sizeMatch?.[1] ?? '',
    })
  }

  return rows.slice(0, 30)
}

async function searchIsohuntHost(
  base: string,
  query: string
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim())
  const searchUrl = `${base}/search/?q=${slug}`

  try {
    const html = await fetchHTML(searchUrl)
    if (!html) return []

    const parsed = parseIsohuntRows(html)
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
        trackerSource: 'IsoHunt',
      })
    }

    return hits
  } catch {
    return []
  }
}

export const isohuntIndexer: TorrentIndexer = {
  id: 'isohunt',
  displayName: 'IsoHunt',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = [
      'https://isohunt.to',
      'https://isohunt.app',
    ]

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchIsohuntHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
