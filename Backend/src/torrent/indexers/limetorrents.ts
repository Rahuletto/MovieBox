import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, hashFromMagnet, parseSizeBytes, resolveQualityLabel } from '../utils'

export interface RowLimeTorrents {
  title: string
  magnetUri: string
  seeders: number
  leechers: number
  sizeText: string
}

function parseLimeTorrentsRows(html: string): RowLimeTorrents[] {
  const rows: RowLimeTorrents[] = []
  // Parse table rows - look for <tr> containing torrent data
  const chunks = html.split(/<tr[\s>]/i).filter((c) => c.includes('href='))

  for (const chunk of chunks) {
    // Extract title and magnet link
    const titleMatch = chunk.match(/<a[^>]*href="([^"]*)"[^>]*>([^<]+)<\/a>/i)
    const magnetMatch = chunk.match(/href="(magnet:\?[^"]+)"/i)

    if (!titleMatch || !magnetMatch) continue

    // Extract seeders/leechers (usually in <td> tags with specific class)
    const seedersMatch = chunk.match(/>(\d+)<\/td>\s*<td[^>]*>(\d+)<\/td>/)
    const sizeMatch = chunk.match(/>([^<]*(?:GB|MB|KB|B)<[^>]*)/)

    rows.push({
      title: decodeHtml(titleMatch[2].trim()),
      magnetUri: decodeHtml(magnetMatch[1]),
      seeders: seedersMatch ? parseInt(seedersMatch[1], 10) : 0,
      leechers: seedersMatch ? parseInt(seedersMatch[2], 10) : 0,
      sizeText: sizeMatch?.[1]?.trim() ?? '',
    })
  }

  return rows.slice(0, 25)
}

async function searchLimeTorrentsHost(
  base: string,
  query: string
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim()).replace(/%20/g, '+')
  const searchUrl = `${base}/search/all/${slug}/`

  const html = await fetchHTML(searchUrl)
  if (!html) return []

  const parsed = parseLimeTorrentsRows(html)
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
      sizeBytes: parseSizeBytes(row.sizeText),
      seeders: row.seeders,
      leechers: row.leechers,
      trackerSource: 'LimeTorrents',
    })
  }

  return hits
}

export const limeTorrentsIndexer: TorrentIndexer = {
  id: 'limetorrents',
  displayName: 'LimeTorrents',

  supports() {
    return true
  },

  async search(ctx) {
    const hosts = [
      'https://www.limetorrents.lol',
      'https://www.limetorrents.info',
      'https://limetorrents.zone',
    ]

    for (const base of hosts) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const rows = await searchLimeTorrentsHost(base, ctx.query)
        if (rows.length) return rows
      } catch {
        // Try next host
      }
    }
    return []
  },
}
