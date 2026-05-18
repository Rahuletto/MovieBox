import type { SearchContext, TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, magnetFor, normalizeImdb, resolveQualityLabel } from '../utils'

export const eztvIndexer: TorrentIndexer = {
  id: 'eztv',
  displayName: 'EZTV',

  supports(ctx) {
    return ctx.kind === 'tv'
  },

  async search(ctx) {
    const imdb = normalizeImdb(ctx.imdbId)
    const cleanImdb = imdb ? imdb.replace(/^tt/, '') : null
    for (const host of ['eztv.wf', 'eztvx.to', 'eztv.re']) {
      const params = new URLSearchParams({ limit: '100' })
      if (cleanImdb) params.set('imdb_id', cleanImdb)
      else params.set('search_term', ctx.query)

      const url = `https://${host}/api/get-torrents?${params}`
      const data = await fetchJSON<{ torrents?: Array<Record<string, unknown>> }>(url)
      const rows = data?.torrents
      if (!rows?.length) continue

      return rows
        .map((row) => {
          const title = String(row.title ?? row.filename ?? 'Unknown')
          const hash = String(row.info_hash ?? row.hash ?? '').toLowerCase()
          if (!hash) return null
          const magnet =
            typeof row.magnet_url === 'string' && row.magnet_url.length > 0
              ? row.magnet_url
              : magnetFor(hash, title)
          return {
            title,
            magnetURI: magnet,
            infoHash: hash,
            quality: resolveQualityLabel(undefined, title),
            sizeBytes: Number(row.size_bytes ?? 0),
            seeders: Number(row.seeds ?? 0),
            leechers: Number(row.peers ?? 0),
            trackerSource: 'EZTV',
          } satisfies TorrentSearchHit
        })
        .filter((r): r is TorrentSearchHit => r !== null)
    }
    return []
  },
}
