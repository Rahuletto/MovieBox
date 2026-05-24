import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, hashFromMagnet, parseSizeBytes, resolveQualityLabel, searchWithQueryVariants } from '../utils'

function parseBitsearchRows(html: string): Array<{
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

  // Bitsearch uses <div class="result"> structure
  const resultRegex = /<div[^>]*class="[^"]*result[^"]*"[^>]*>([\s\S]*?)<\/div>\s*<\/div>/gi
  let match: RegExpExecArray | null

  while ((match = resultRegex.exec(html)) !== null) {
    const item = match[1]

    // Extract title and magnet
    const titleMatch = item.match(/<a[^>]*href="[^"]*"[^>]*>([^<]+)<\/a>/i)
    if (!titleMatch) continue

    const magnetMatch = item.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Extract seeders/leechers (usually shown as "1234 seeders, 567 leechers")
    const statsMatch = item.match(/(\d+)\s+seeders?[\s,]+(\d+)\s+leechers?/i) ||
      item.match(/seeders?[:\s]+(\d+)[\s\S]*?leechers?[:\s]+(\d+)/i)

    // Extract size
    const sizeMatch = item.match(/(\d+(?:\.\d+)?\s*(?:GB|MB|KB))/i)

    rows.push({
      title: decodeHtml(titleMatch[1].trim()),
      magnet: decodeHtml(magnetMatch[1]),
      seeders: statsMatch ? parseInt(statsMatch[1], 10) : 0,
      leechers: statsMatch ? parseInt(statsMatch[2], 10) : 0,
      size: sizeMatch?.[1] ?? '',
    })
  }

  return rows.slice(0, 30)
}

async function searchBitsearchHost(
  base: string,
  query: string
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim())
  const searchUrl = `${base}/search?q=${slug}&sort=seeders`

  try {
    const html = await fetchHTML(searchUrl)
    if (!html) return []

    const parsed = parseBitsearchRows(html)
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
        trackerSource: 'Bitsearch',
      })
    }

    return hits
  } catch {
    return []
  }
}

export const bitsearchIndexer: TorrentIndexer = {
  id: 'bitsearch',
  displayName: 'Bitsearch',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = [
      'https://bitsearch.to',
      'https://www.bitsearch.to',
    ]

    return searchWithQueryVariants(ctx.query, ctx.year, async (query) => {
      for (const base of hosts) {
        try {
          const rows = await searchBitsearchHost(base, query)
          if (rows.length) return rows
        } catch {
          // Try next host / query variant
        }
      }
      return []
    })
  },
}
