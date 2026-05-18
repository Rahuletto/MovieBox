import type { SearchContext, TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, magnetFor, normalizeImdb, resolveQualityLabel } from '../utils'

export const torrentioIndexer: TorrentIndexer = {
  id: 'torrentio',
  displayName: 'Torrentio',

  supports(ctx) {
    return Boolean(normalizeImdb(ctx.imdbId))
  },

  async search(ctx) {
    const cleanId = normalizeImdb(ctx.imdbId)
    if (!cleanId) return []

    const mediaPath = ctx.kind === 'tv' ? 'series' : 'movie'
    // Torrentio's series endpoint requires `imdbid:season:episode`. Without
    // the suffix it returns zero streams. If no season/episode was parsed
    // out of the query, fall back to S1E1 so the user gets *something*
    // rather than an empty list.
    let id = cleanId
    if (ctx.kind === 'tv') {
      const s = ctx.season ?? 1
      const e = ctx.episode ?? 1
      id = `${cleanId}:${s}:${e}`
    }
    const url = `https://torrentio.strem.fun/providers=yts,eztv,rarbg,1337x,kickass,thepiratebay,torrentproject,limetorrents,zooqle,tgx/stream/${mediaPath}/${id}.json`
    const data = await fetchJSON<{ streams?: Array<{ title: string; infoHash: string }> }>(url)
    const streams = data?.streams ?? []

    return streams
      .filter((s) => s.infoHash)
      .map((stream) => {
        const lines = stream.title.split('\n')
        const detailsLine = lines[1] ?? stream.title
        const metadataLine = lines[2] ?? ''
        const movieTitle = lines[0] ?? 'Unknown'

        let seeders = 0
        let leechers = 0
        const seedMatch = metadataLine.match(/👤\s*(\d+)/) ?? stream.title.match(/S:\s*(\d+)/)
        const peerMatch = metadataLine.match(/👥\s*(\d+)/)
        if (seedMatch) seeders = parseInt(seedMatch[1], 10)
        if (peerMatch) leechers = parseInt(peerMatch[1], 10)

        return {
          title: movieTitle,
          magnetURI: magnetFor(stream.infoHash, movieTitle),
          infoHash: stream.infoHash.toLowerCase(),
          quality: resolveQualityLabel(detailsLine, `${movieTitle}\n${stream.title}`),
          sizeBytes: 0,
          seeders,
          leechers,
          trackerSource: 'Torrentio',
        } satisfies TorrentSearchHit
      })
  },
}
