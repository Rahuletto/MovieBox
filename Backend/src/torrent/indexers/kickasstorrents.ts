import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, hashFromMagnet, parseSizeBytes, resolveQualityLabel } from '../utils'

function parseKATRows(html: string): Array<{
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

  // KAT uses table structure with torrent rows
  const tableRowRegex = /<tr[\s>]([\s\S]*?)<\/tr>/gi
  let match: RegExpExecArray | null

  while ((match = tableRowRegex.exec(html)) !== null) {
    const rowHtml = match[1]

    // Skip header rows
    if (rowHtml.includes('<th') || !rowHtml.includes('magnet:')) continue

    // Extract title from link
    const titleMatch = rowHtml.match(/<a[^>]*href="\/torrent\/[^"]*"[^>]*>([^<]+)<\/a>/i)
    if (!titleMatch) continue

    // Extract magnet link
    const magnetMatch = rowHtml.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Extract seeders/leechers from td elements
    const tds = rowHtml.match(/<td[^>]*>([^<]*)<\/td>/gi) || []
    let seeders = 0
    let leechers = 0
    let size = ''

    if (tds.length >= 4) {
      // Usually: Name | Size | Seeders | Leechers
      size = tds[1]?.replace(/<[^>]*>/g, '').trim() || ''
      seeders = parseInt(tds[2]?.replace(/<[^>]*>/g, '') || '0', 10)
      leechers = parseInt(tds[3]?.replace(/<[^>]*>/g, '') || '0', 10)
    }

    rows.push({
      title: decodeHtml(titleMatch[1].trim()),
      magnetUri: decodeHtml(magnetMatch[1]),
      seeders,
      leechers,
      size,
    })
  }

  return rows.slice(0, 25)
}

async function searchKATHost(
  base: string,
  query: string
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim()).replace(/%20/g, '+')
  const searchUrl = `${base}/search/${slug}/`

  try {
    const html = await fetchHTML(searchUrl)
    if (!html) return []

    const parsed = parseKATRows(html)
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
        trackerSource: 'KickassTorrents',
      })
    }

    return hits
  } catch {
    return []
  }
}

export const kickassTorrentsIndexer: TorrentIndexer = {
  id: 'kickasstorrents',
  displayName: 'KickassTorrents',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = [
      'https://www.kickasstorrents.to',
      'https://kickasstorrents.cc',
      'https://katcr.co',
    ]

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchKATHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
