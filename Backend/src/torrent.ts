/**
 * Built-in torrent indexers (YTS, EZTV, Pirate Bay via apibay).
 * Runs on the Worker so the Mac app can search even when indexer APIs block direct clients.
 */

const USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

export type TorrentKind = 'movie' | 'tv'

export interface TorrentSearchHit {
  title: string
  magnetURI: string
  infoHash: string | null
  quality: string
  sizeBytes: number
  seeders: number
  leechers: number
  trackerSource: string
}

function magnetFor(infoHash: string, title: string): string {
  const hash = infoHash.replace(/^urn:btih:/i, '').toLowerCase()
  const dn = encodeURIComponent(title)
  return `magnet:?xt=urn:btih:${hash}&dn=${dn}`
}

function sanitizeQuery(title: string, year?: number | null): string {
  const cleaned = title.replace(/%/g, '').trim()
  if (!cleaned) return title.trim()
  if (year && year >= 1900 && year <= 2100) return `${cleaned} ${year}`
  return cleaned
}

function normalizeImdb(raw?: string | null): string | null {
  if (!raw) return null
  let value = raw.trim()
  if (!value) return null
  if (!value.startsWith('tt')) value = `tt${value}`
  return value
}

async function fetchJSON<T>(url: string): Promise<T | null> {
  const res = await fetch(url, {
    headers: { 'User-Agent': USER_AGENT },
    cf: { cacheTtl: 300, cacheEverything: true },
  })
  if (!res.ok) return null
  return (await res.json()) as T
}

async function searchYTS(query: string): Promise<TorrentSearchHit[]> {
  const hosts = ['yts.mx', 'yts.pm', 'yts.lt']
  for (const host of hosts) {
    const url = `https://${host}/api/v2/list_movies.json?query_term=${encodeURIComponent(query)}`
    const data = await fetchJSON<{
      data?: { movies?: Array<{ title?: string; torrents?: Array<{ hash: string; quality: string; size_bytes: number; seeds: number; peers: number }> }> }
    }>(url)
    const movies = data?.data?.movies
    if (!movies?.length) continue

    const hits: TorrentSearchHit[] = []
    for (const movie of movies) {
      const title = movie.title ?? 'Unknown'
      for (const t of movie.torrents ?? []) {
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
    }
    if (hits.length) return hits
  }
  return []
}

async function searchEZTV(query: string, imdbId: string | null): Promise<TorrentSearchHit[]> {
  const hosts = ['eztv.wf', 'eztvx.to', 'eztv.re']
  for (const host of hosts) {
    const params = new URLSearchParams({ limit: '100' })
    if (imdbId) params.set('imdb_id', imdbId)
    else params.set('search_term', query)

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
          quality: '720p',
          sizeBytes: Number(row.size_bytes ?? 0),
          seeders: Number(row.seeds ?? 0),
          leechers: Number(row.peers ?? 0),
          trackerSource: 'EZTV',
        } satisfies TorrentSearchHit
      })
      .filter((r): r is TorrentSearchHit => r !== null)
  }
  return []
}

async function searchPirateBay(query: string, kind: TorrentKind): Promise<TorrentSearchHit[]> {
  const cat = kind === 'tv' ? '205' : '207'
  const url = `https://apibay.org/q.php?q=${encodeURIComponent(query)}&cat=${cat}`
  const rows = await fetchJSON<Array<Record<string, string>>>(url)
  if (!rows?.length) return []

  return rows
    .filter((row) => row.id !== '0' && row.name)
    .map((row) => {
      const name = row.name!
      const hash = (row.info_hash ?? '').toLowerCase()
      if (hash.length !== 40) return null
      return {
        title: name,
        magnetURI: magnetFor(hash, name),
        infoHash: hash,
        quality: '720p',
        sizeBytes: Number(row.size ?? 0),
        seeders: Number(row.seeders ?? 0),
        leechers: Number(row.leechers ?? 0),
        trackerSource: 'Pirate Bay',
      } satisfies TorrentSearchHit
    })
    .filter((r): r is TorrentSearchHit => r !== null)
}

export async function searchTorrentIndexers(opts: {
  query: string
  year?: number | null
  imdbId?: string | null
  kind: TorrentKind
  enableYTS: boolean
}): Promise<{ results: TorrentSearchHit[]; counts: Record<string, number>; errors: Record<string, string> }> {
  const q = sanitizeQuery(opts.query, opts.year)
  const imdb = normalizeImdb(opts.imdbId)
  const counts: Record<string, number> = {}
  const errors: Record<string, string> = {}
  const merged: TorrentSearchHit[] = []
  const seen = new Set<string>()

  const add = (id: string, rows: TorrentSearchHit[]) => {
    counts[id] = rows.length
    for (const row of rows) {
      const key = row.infoHash?.toLowerCase()
      if (key && seen.has(key)) continue
      if (key) seen.add(key)
      merged.push(row)
    }
  }

  const tasks: Array<Promise<void>> = []

  if (opts.kind === 'movie' && opts.enableYTS) {
    tasks.push(
      searchYTS(q)
        .then((rows) => add('yts', rows))
        .catch((e) => {
          errors.yts = String(e)
          counts.yts = 0
        })
    )
  }

  if (opts.kind === 'tv') {
    tasks.push(
      searchEZTV(q, imdb)
        .then((rows) => add('eztv', rows))
        .catch((e) => {
          errors.eztv = String(e)
          counts.eztv = 0
        })
    )
  }

  tasks.push(
    searchPirateBay(q, opts.kind)
      .then((rows) => add('piratebay', rows))
      .catch((e) => {
        errors.piratebay = String(e)
        counts.piratebay = 0
      })
  )

  await Promise.all(tasks)

  return { results: merged, counts, errors }
}
