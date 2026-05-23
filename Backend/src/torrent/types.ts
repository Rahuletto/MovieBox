export const TORRENT_API_VERSION = 3

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
  /** Canonical indexer id (e.g. `piratebay`) — set when merging indexer batches. */
  indexerId?: string
}

export interface SearchContext {
  query: string
  year: number | null
  imdbId: string | null
  kind: TorrentKind
  enableYTS: boolean
  /** Parsed from the query when present (e.g. "The Boys S01E03 2019"). */
  season: number | null
  episode: number | null
}

export interface TorrentSearchPayload {
  results: TorrentSearchHit[]
  counts: Record<string, number>
  errors: Record<string, string>
  query: string
  torrentio: { attempted: boolean; count: number; error: string | null }
  apiVersion: number
}

/** Pluggable indexer (cf. torrent-indexer Source / Torrents-Api per-site modules). */
export interface TorrentIndexer {
  id: string
  displayName: string
  supports(ctx: SearchContext): boolean
  search(ctx: SearchContext): Promise<TorrentSearchHit[]>
}
