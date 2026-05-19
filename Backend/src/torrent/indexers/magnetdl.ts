import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, hashFromMagnet, parseSizeBytes, resolveQualityLabel } from '../utils'

function parseMagnetDLRows(html: string): Array<{
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

  // MagnetDL uses <tr> table rows
  const tableRows = html.split(/<tr[^>]*>/i)

  for (const row of tableRows) {
    // Look for magnet link in <a href="magnet:...">
    const magnetMatch = row.match(/href="(magnet:\?[^"]+)"/i)
    if (!magnetMatch) continue

    // Title is usually first <td> content or anchor text
    const titleMatch =
      row.match(/><td[^>]*>([^<]*)<a/) ||
      row.match(/href="magnet:\?[^"]*"[^>]*>([^<]+)</)
    if (!titleMatch) continue

    // Extract stats - seeders and leechers in <td> tags
    const tds = row.match(/<td[^>]*>([^<]*)<\/td>/gi) || []
    let seeders = 0
    let leechers = 0
    let size = ''

    if (tds.length >= 3) {
      seeders = parseInt(tds[tds.length - 2].replace(/<[^>]*>/g, ''), 10) || 0
      leechers = parseInt(tds[tds.length - 1].replace(/<[^>]*>/g, ''), 10) || 0
    }

    const sizeMatch = row.match(/(\d+(?:\.\d+)?\s*(?:GB|MB|KB))/i)
    size = sizeMatch?.[1] ?? ''

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

async function searchMagnetDLHost(
  base: string,
  query: string
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim()).replace(/%20/g, '+')
  const searchUrl = `${base}/?q=${slug}&sort=seeders`

  const html = await fetchHTML(searchUrl)
  if (!html) return []

  const parsed = parseMagnetDLRows(html)
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
      trackerSource: 'MagnetDL',
    })
  }

  return hits
}

export const magnetDLIndexer: TorrentIndexer = {
  id: 'magnetdl',
  displayName: 'MagnetDL',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = ['https://www.magnetdl.com', 'https://magnetdl.org']

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchMagnetDLHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
