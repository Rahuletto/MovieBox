import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, hashFromMagnet, parseSizeBytes, resolveQualityLabel } from '../utils'

function parseTorrentGalaxyRows(html: string): Array<{
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

  // Look for torrent entries in div.tgxtable-item or similar structure
  const itemRegex = /<div[^>]*class="[^"]*tgxtable[^"]*"[^>]*>([\s\S]*?)<\/div>\s*<\/div>/gi
  let match: RegExpExecArray | null

  while ((match = itemRegex.exec(html)) !== null) {
    const item = match[1]

    // Extract title
    const titleMatch = item.match(/<a[^>]*href="\/torrent\/[^"]*"[^>]*>([^<]+)<\/a>/i)
    if (!titleMatch) continue

    // Extract magnet
    const magnetMatch = item.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Extract seeders/leechers (usually in span with text or numbers)
    const statsMatch = item.match(
      /seeders?[:\s]*(\d+)[\s\S]*?leechers?[:\s]*(\d+)/i
    ) || item.match(/>(\d+)\s+([sS]eeds?)<[\s\S]*?>(\d+)\s+([lL]eech)/i)

    const seeders = statsMatch ? parseInt(statsMatch[1], 10) : 0
    const leechers = statsMatch
      ? parseInt(statsMatch[statsMatch.length > 2 ? 3 : 2], 10)
      : 0

    // Extract size
    const sizeMatch = item.match(/(\d+(?:\.\d+)?\s*(?:GB|MB|KB))/i)

    rows.push({
      title: decodeHtml(titleMatch[1].trim()),
      magnet: decodeHtml(magnetMatch[1]),
      seeders,
      leechers,
      size: sizeMatch?.[1] ?? '',
    })
  }

  return rows.slice(0, 25)
}

async function searchTorrentGalaxyHost(
  base: string,
  query: string
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim()).replace(/%20/g, '+')
  const searchUrl = `${base}/torrents.php?search=${slug}&sort=seeders&order=desc`

  const html = await fetchHTML(searchUrl)
  if (!html) return []

  const parsed = parseTorrentGalaxyRows(html)
  if (!parsed.length) return []

  const hits: TorrentSearchHit[] = []
  for (const row of parsed.slice(0, 15)) {
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
      trackerSource: 'TorrentGalaxy',
    })
  }

  return hits
}

export const torrentGalaxyIndexer: TorrentIndexer = {
  id: 'torrentgalaxy',
  displayName: 'TorrentGalaxy',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = [
      'https://www.torrentgalaxy.to',
      'https://torrentgalaxy.org',
      'https://tgx.rs',
    ]

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchTorrentGalaxyHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
