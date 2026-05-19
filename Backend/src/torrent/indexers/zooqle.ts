import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, hashFromMagnet, parseSizeBytes, resolveQualityLabel } from '../utils'

function parseZooqleRows(html: string): Array<{
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

  // Zooqle uses <div class="item"> structure
  const itemRegex = /<div[^>]*class="[^"]*item[^"]*"[^>]*>([\s\S]*?)<\/div>\s*<\/div>/gi
  let match: RegExpExecArray | null

  while ((match = itemRegex.exec(html)) !== null) {
    const item = match[1]

    // Extract title and magnet from link
    const titleMatch = item.match(
      /<a[^>]*href="[^"]*"[^>]*title="([^"]+)"[^>]*>([^<]+)<\/a>/i
    ) || item.match(/<span[^>]*class="[^"]*title[^"]*"[^>]*>([^<]+)<\/span>/i)
    if (!titleMatch) continue

    const magnetMatch = item.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Extract seeders/leechers
    const statsMatch = item.match(
      /class="[^"]*seeders?[^"]*"[^>]*>(\d+)<[\s\S]*?class="[^"]*leechers?[^"]*"[^>]*>(\d+)</i
    )

    // Extract size
    const sizeMatch = item.match(/(\d+(?:\.\d+)?\s*(?:GB|MB|KB))/i)

    rows.push({
      title: decodeHtml(titleMatch[titleMatch.length - 1].trim()),
      magnet: decodeHtml(magnetMatch[1]),
      seeders: statsMatch ? parseInt(statsMatch[1], 10) : 0,
      leechers: statsMatch ? parseInt(statsMatch[2], 10) : 0,
      size: sizeMatch?.[1] ?? '',
    })
  }

  return rows.slice(0, 30)
}

async function searchZooqleHost(
  base: string,
  query: string
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim())
  const searchUrl = `${base}/search?q=${slug}&fmt=rss`

  try {
    const html = await fetchHTML(searchUrl)
    if (!html) return []

    const parsed = parseZooqleRows(html)
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
        trackerSource: 'Zooqle',
      })
    }

    return hits
  } catch {
    return []
  }
}

export const zooqleIndexer: TorrentIndexer = {
  id: 'zooqle',
  displayName: 'Zooqle',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = [
      'https://zooqle.com',
      'https://www.zooqle.com',
    ]

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchZooqleHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
