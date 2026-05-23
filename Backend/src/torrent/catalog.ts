import type { TorrentKind } from './types'

export interface IndexerCatalogEntry {
  id: string
  name: string
  description: string
  kinds: TorrentKind[]
  defaultEnabled: boolean
}

/** Canonical list — drives /api/config and default client toggles. */
export const INDEXER_CATALOG: IndexerCatalogEntry[] = [
  {
    id: 'torrentio',
    name: 'Torrentio',
    description: 'Aggregator (needs IMDb id from metadata)',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'yts',
    name: 'YTS',
    description: 'Compact movie releases (ytsweb + mirrors)',
    kinds: ['movie'],
    defaultEnabled: true,
  },
  {
    id: 'eztv',
    name: 'EZTV',
    description: 'TV episodes and seasons',
    kinds: ['tv'],
    defaultEnabled: true,
  },
  {
    id: 'piratebay',
    name: 'Pirate Bay',
    description: 'General search via apibay',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: '1337x',
    name: '1337x',
    description: 'Wide scene releases',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'nyaa',
    name: 'Nyaa',
    description: 'Anime torrents (SubGroup releases)',
    kinds: ['tv'],
    defaultEnabled: true,
  },
  {
    id: 'limetorrents',
    name: 'LimeTorrents',
    description: 'General movies & TV releases',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'torrentgalaxy',
    name: 'TorrentGalaxy',
    description: 'Movies, TV, and diverse content',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'magnetdl',
    name: 'MagnetDL',
    description: 'Quick magnet search engine',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'solidtorrents',
    name: 'Solid Torrents',
    description: 'Decentralized torrent search API',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'rutracker',
    name: 'RuTracker',
    description: 'Russian tracker with extensive catalog',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'kickasstorrents',
    name: 'KickassTorrents',
    description: 'Community torrent releases',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'rarbg',
    name: 'RARBG',
    description: 'Shut down May 2023 — kept for legacy compatibility',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'zooqle',
    name: 'Zooqle',
    description: 'Defunct tracker — kept for legacy compatibility',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'torrentfunk',
    name: 'TorrentFunk',
    description: 'Movies and TV with many seeders',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'isohunt',
    name: 'IsoHunt',
    description: 'Defunct tracker — kept for legacy compatibility',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'torrentdownload',
    name: 'Torrent Download',
    description: 'Clean search interface, good coverage',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
  {
    id: 'bitsearch',
    name: 'Bitsearch',
    description: 'Modern aggregator with high seeders',
    kinds: ['movie', 'tv'],
    defaultEnabled: false,
  },
]

export const DEFAULT_ENABLED_INDEXER_IDS = INDEXER_CATALOG.filter((e) => e.defaultEnabled).map(
  (e) => e.id
)

/** Every catalog indexer — used when the client omits `enabled` (Settings filter is app-side). */
export const ALL_INDEXER_IDS = INDEXER_CATALOG.map((e) => e.id)

export function parseEnabledIndexerIDs(raw: string | null | undefined): Set<string> {
  const known = new Set(INDEXER_CATALOG.map((e) => e.id))
  // macOS app no longer sends `enabled`; run the full catalog and let the client filter.
  if (raw === null || raw === undefined || raw.trim() === '') {
    return new Set(ALL_INDEXER_IDS)
  }
  const ids = new Set(
    raw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter((id) => known.has(id))
  )
  return ids
}
