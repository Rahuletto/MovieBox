import type { TorrentIndexer, TorrentSearchHit } from '../types'
import {
  decodeHtml,
  fetchHTML,
  hashFromMagnet,
  parseSizeBytes,
  resolveQualityLabel,
} from '../utils'

function parseRutrackerRows(html: string): Array<{
  title: string
  magnetUri: string
  seeders: number
  leechers: number
  size: string
}> {
  const rows: Array<{
    title: string
    magnetUri: string
    seeders: number
    leechers: number
    size: string
  }> = []

  // RuTracker uses <tr> with specific structure
  const tableRegex = /<tr[^>]*id="tr-(\d+)"[^>]*>([\s\S]*?)<\/tr>/gi
  let match: RegExpExecArray | null

  while ((match = tableRegex.exec(html)) !== null) {
    const rowHtml = match[2]

    // Extract title from link
    const titleMatch =
      rowHtml.match(/<a[^>]*href="[^"]*"[^>]*title="([^"]+)"/i) ||
      rowHtml.match(/<b[^>]*>([^<]+)<\/b>/i)
    if (!titleMatch) continue

    // Extract magnet link
    const magnetMatch = rowHtml.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Extract seeders and leechers
    const seedMatch = rowHtml.match(/class="[^"]*green[^"]*">(\d+)</)
    const leechMatch = rowHtml.match(/class="[^"]*red[^"]*">(\d+)</)

    // Extract size
    const sizeMatch = rowHtml.match(/>(\d+(?:\.\d+)?\s*(?:GB|MB|KB))</)

    rows.push({
      title: decodeHtml(titleMatch[1].trim()),
      magnetUri: decodeHtml(magnetMatch[1]),
      seeders: seedMatch ? parseInt(seedMatch[1], 10) : 0,
      leechers: leechMatch ? parseInt(leechMatch[1], 10) : 0,
      size: sizeMatch?.[1] ?? '',
    })
  }

  return rows.slice(0, 25)
}

async function searchRutrackerHost(base: string, query: string): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim())
  const searchUrl = `${base}/forum/tracker.php?nm=${slug}&o=10&s=2`

  try {
    const html = await fetchHTML(searchUrl)
    if (!html) return []

    const parsed = parseRutrackerRows(html)
    if (!parsed.length) return []

    const hits: TorrentSearchHit[] = []
    for (const row of parsed.slice(0, 15)) {
      const hash = hashFromMagnet(row.magnetUri)
      if (!hash) continue

      hits.push({
        title: row.title,
        magnetURI: row.magnetUri,
        infoHash: hash,
        quality: resolveQualityLabel(undefined, row.title),
        sizeBytes: parseSizeBytes(row.size),
        seeders: row.seeders,
        leechers: row.leechers,
        trackerSource: 'RuTracker',
      })
    }

    return hits
  } catch {
    return []
  }
}

export const rutrackerIndexer: TorrentIndexer = {
  id: 'rutracker',
  displayName: 'RuTracker',

  supports() {
    return true
  },

  async search(ctx) {
    // RuTracker works best with Russian mirrors/proxies
    const hosts = ['https://rutracker.org', 'https://bt.rutracker.org']

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchRutrackerHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
