import type { TorrentIndexer, TorrentSearchHit } from '../types'
import {
  decodeHtml,
  fetchHTML,
  hashFromMagnet,
  parseSizeBytes,
  resolveQualityLabel,
  searchWithQueryVariants,
} from '../utils'

export interface Row1337x {
  path: string
  title: string
  seeders: number
  leechers: number
  sizeText: string
}

/** Parse 1337x / 1337xx search table rows. */
export function parse1337xSearchRows(html: string): Row1337x[] {
  const rows: Row1337x[] = []
  const chunks = html.split(/<tr[\s>]/i).filter((c) => c.includes('/torrent/'))

  for (const chunk of chunks) {
    const pathMatch = chunk.match(/href="(\/torrent\/\d+\/[^"]+)"/i)
    const titleMatch = chunk.match(/href="\/torrent\/\d+\/[^"]*"[^>]*>([^<]+)</i)
    const seedsMatch = chunk.match(/class="coll-2[^"]*"[^>]*>\s*(\d+)/i)
    const leechMatch = chunk.match(/class="coll-3[^"]*"[^>]*>\s*(\d+)/i)
    const sizeMatch = chunk.match(/class="coll-4[^"]*"[^>]*>\s*([^<]+)</i)
    if (!pathMatch || !titleMatch) continue

    rows.push({
      path: pathMatch[1],
      title: decodeHtml(titleMatch[1].trim()),
      seeders: parseInt(seedsMatch?.[1] ?? '0', 10),
      leechers: parseInt(leechMatch?.[1] ?? '0', 10),
      sizeText: sizeMatch?.[1]?.trim() ?? '',
    })
  }

  return rows.slice(0, 24)
}

/** Parse search page link list (Ryuk-me Torrents-Api / td.name second anchor pattern). */
export function parse1337xDetailPaths(html: string): string[] {
  const paths: string[] = []
  const regex = /href="(\/torrent\/\d+\/[^"]+)"/gi
  let m: RegExpExecArray | null
  while ((m = regex.exec(html)) !== null) {
    if (!paths.includes(m[1])) paths.push(m[1])
  }
  return paths.slice(0, 20)
}

async function fetch1337xMagnet(
  base: string,
  path: string
): Promise<{ magnet: string; hash: string } | null> {
  const html = await fetchHTML(`${base}${path}`)
  if (!html) return null

  // Ryuk-me: magnet in .clearfix ul li a
  const magnetMatch = html.match(/href="(magnet:\?xt=urn:btih:[^"]+)"/i)
  if (!magnetMatch) return null

  const magnet = decodeHtml(magnetMatch[1])
  const hash = hashFromMagnet(magnet)
  if (!hash) return null
  return { magnet, hash }
}

async function search1337xHost(
  base: string,
  query: string,
  category?: 'Movies' | 'TV'
): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim()).replace(/%20/g, '+')
  const searchUrls = category
    ? [`${base}/category-search/${slug}/${category}/1/`]
    : [`${base}/sort-search/${slug}/seeders/desc/1/`, `${base}/search/${slug}/1/`]

  for (const searchUrl of searchUrls) {
    const html = await fetchHTML(searchUrl)
    if (!html) continue

    const parsed = parse1337xSearchRows(html)
    const paths =
      parsed.length > 0
        ? parsed.map((r) => ({
            path: r.path,
            title: r.title,
            seeders: r.seeders,
            leechers: r.leechers,
            sizeText: r.sizeText,
          }))
        : parse1337xDetailPaths(html).map((path) => ({
            path,
            title: query,
            seeders: 0,
            leechers: 0,
            sizeText: '',
          }))

    if (!paths.length) continue

    const hits: TorrentSearchHit[] = []
    await Promise.all(
      paths.slice(0, 10).map(async (row) => {
        const mag = await fetch1337xMagnet(base, row.path)
        if (!mag) return
        hits.push({
          title: row.title,
          magnetURI: mag.magnet,
          infoHash: mag.hash,
          quality: resolveQualityLabel(undefined, row.title),
          sizeBytes: parseSizeBytes(row.sizeText),
          seeders: row.seeders,
          leechers: row.leechers,
          trackerSource: '1337x',
        })
      })
    )

    if (hits.length) return hits
  }
  return []
}

export const x1337Indexer: TorrentIndexer = {
  id: '1337x',
  displayName: '1337x',

  supports() {
    return true
  },

  async search(ctx) {
    const category = ctx.kind === 'tv' ? 'TV' : 'Movies'
    const hosts = ['https://1337xx.to', 'https://1337x.to', 'https://1337x.st', 'https://x1337x.ws']

    return searchWithQueryVariants(ctx.query, ctx.year, async (query) => {
      for (const base of hosts) {
        const rows = await search1337xHost(base, query, category)
        if (rows.length) return rows
        const generic = await search1337xHost(base, query)
        if (generic.length) return generic
      }
      return []
    })
  },
}
