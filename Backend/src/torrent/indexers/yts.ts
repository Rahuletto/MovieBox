import type { TorrentIndexer, TorrentSearchHit } from '../types'
import { decodeHtml, fetchHTML, fetchJSON, magnetFor, searchWithQueryVariants } from '../utils'

interface YTSWebResult {
  id: number
  title: string
  year: string
  url: string
}

function mapYtsTorrents(
  title: string,
  torrents: Array<{
    hash: string
    quality: string
    size_bytes?: number
    seeds?: number
    peers?: number
  }>
): TorrentSearchHit[] {
  const hits: TorrentSearchHit[] = []
  for (const t of torrents) {
    if (!t.hash) continue
    hits.push({
      title: `${title} [${t.quality}]`,
      magnetURI: magnetFor(t.hash, title),
      infoHash: t.hash.toLowerCase(),
      quality: t.quality,
      sizeBytes: t.size_bytes ?? 0,
      seeders: t.seeds ?? 0,
      leechers: t.peers ?? 0,
      trackerSource: 'YTS',
    })
  }
  return hits
}

function pickYTSWebResult(results: YTSWebResult[], year: number | null): YTSWebResult | null {
  if (!results.length) return null
  if (year) {
    const exact = results.find((r) => r.year === String(year))
    if (exact) return exact
  }
  return results[0]
}

async function fetchYTSMovieDetailsById(tmdbId: number): Promise<TorrentSearchHit[]> {
  for (const host of ['yts.mx', 'yts.lt', 'yts.pm', 'yts.am']) {
    const url = `https://${host}/api/v2/movie_details.json?movie_id=${tmdbId}`
    const data = await fetchJSON<{
      data?: {
        movie?: {
          title?: string
          torrents?: Array<{
            hash: string
            quality: string
            size_bytes?: number
            seeds?: number
            peers?: number
          }>
        }
      }
    }>(url)
    const movie = data?.data?.movie
    if (movie?.torrents?.length) return mapYtsTorrents(movie.title ?? 'Unknown', movie.torrents)
  }
  return []
}

async function scrapeYTSWebFilm(filmUrl: string): Promise<TorrentSearchHit[]> {
  const html = await fetchHTML(filmUrl, 'https://ytsweb.org/')
  if (!html) return []

  const titleMatch = html.match(/<h1[^>]*>([^<]+)</i)
  const title = titleMatch ? decodeHtml(titleMatch[1].trim()) : 'Unknown'
  const hits: TorrentSearchHit[] = []
  const seen = new Set<string>()

  const magnetRegex = /href="(magnet:\?xt=urn:btih:[^"]+)"/gi
  let m: RegExpExecArray | null
  while ((m = magnetRegex.exec(html)) !== null) {
    const magnet = decodeHtml(m[1])
    const hashMatch = magnet.match(/btih:([a-fA-F0-9]{40})/i)
    if (!hashMatch) continue
    const hash = hashMatch[1].toLowerCase()
    if (seen.has(hash)) continue
    seen.add(hash)
    hits.push({
      title,
      magnetURI: magnet,
      infoHash: hash,
      quality: '1080p',
      sizeBytes: 0,
      seeders: 0,
      leechers: 0,
      trackerSource: 'YTS',
    })
  }
  return hits
}

/** ytsweb.org discovery API (user-recommended) + YTS mirror movie_details. */
async function searchYTSWeb(query: string, year: number | null): Promise<TorrentSearchHit[]> {
  const searchUrl = `https://ytsweb.org/api/search/?q=${encodeURIComponent(query)}`
  const data = await fetchJSON<{ results?: YTSWebResult[] }>(searchUrl, 'https://ytsweb.org/')
  const pick = pickYTSWebResult(data?.results ?? [], year)
  if (!pick) return []

  const fromApi = await fetchYTSMovieDetailsById(pick.id)
  if (fromApi.length) return fromApi
  return scrapeYTSWebFilm(pick.url)
}

/** Ryuk-me/Torrents-Api style browse-movies HTML fallback on yts.mx. */
async function searchYTSBrowse(query: string): Promise<TorrentSearchHit[]> {
  const slug = encodeURIComponent(query.trim()).replace(/%20/g, '%20')
  const url = `https://yts.mx/browse-movies/${slug}/all/all/0/latest/0/all`
  const html = await fetchHTML(url)
  if (!html) return []

  const filmPaths: string[] = []
  const pathRegex = /href="(\/movies\/[^"]+)"/gi
  let m: RegExpExecArray | null
  while ((m = pathRegex.exec(html)) !== null) {
    if (!filmPaths.includes(m[1])) filmPaths.push(m[1])
    if (filmPaths.length >= 3) break
  }

  const hits: TorrentSearchHit[] = []
  for (const path of filmPaths) {
    const page = await fetchHTML(`https://yts.mx${path}`)
    if (!page) continue
    const magnetRegex = /href="(magnet:\?[^"]+)"/gi
    while ((m = magnetRegex.exec(page)) !== null) {
      const magnet = decodeHtml(m[1])
      const hash = magnet.match(/btih:([a-fA-F0-9]{40})/i)?.[1]?.toLowerCase()
      if (!hash) continue
      hits.push({
        title: query,
        magnetURI: magnet,
        infoHash: hash,
        quality: page.includes('2160p') ? '2160p' : page.includes('1080p') ? '1080p' : '720p',
        sizeBytes: 0,
        seeders: 0,
        leechers: 0,
        trackerSource: 'YTS',
      })
    }
    if (hits.length) break
  }
  return hits
}

async function searchYTSListMovies(query: string): Promise<TorrentSearchHit[]> {
  for (const host of ['yts.mx', 'yts.pm', 'yts.lt']) {
    const url = `https://${host}/api/v2/list_movies.json?query_term=${encodeURIComponent(query)}`
    const data = await fetchJSON<{
      data?: {
        movies?: Array<{
          title?: string
          torrents?: Array<{
            hash: string
            quality: string
            size_bytes?: number
            seeds?: number
            peers?: number
          }>
        }>
      }
    }>(url)
    const movies = data?.data?.movies
    if (!movies?.length) continue

    const hits: TorrentSearchHit[] = []
    for (const movie of movies)
      hits.push(...mapYtsTorrents(movie.title ?? 'Unknown', movie.torrents ?? []))
    if (hits.length) return hits
  }
  return []
}

export const ytsIndexer: TorrentIndexer = {
  id: 'yts',
  displayName: 'YTS',

  supports(ctx) {
    return ctx.kind === 'movie' && ctx.enableYTS
  },

  async search(ctx) {
    return searchWithQueryVariants(ctx.query, ctx.year, async (query) => {
      try {
        const web = await searchYTSWeb(query, ctx.year)
        if (web.length) return web
      } catch {
        /* fall through */
      }
      const browse = await searchYTSBrowse(query)
      if (browse.length) return browse
      return searchYTSListMovies(query)
    })
  },
}
