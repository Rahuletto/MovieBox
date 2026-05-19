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
    defaultEnabled: true,
  },
  {
    id: 'torrentgalaxy',
    name: 'TorrentGalaxy',
    description: 'Movies, TV, and diverse content',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'magnetdl',
    name: 'MagnetDL',
    description: 'Quick magnet search engine',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'solidtorrents',
    name: 'Solid Torrents',
    description: 'Decentralized torrent search API',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
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
    defaultEnabled: true,
  },
  {
    id: 'rarbg',
    name: 'RARBG',
    description: 'One of the best sources (high seeders)',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'zooqle',
    name: 'Zooqle',
    description: 'Reliable tracker with good coverage',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'torrentfunk',
    name: 'TorrentFunk',
    description: 'Movies and TV with many seeders',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'isohunt',
    name: 'IsoHunt',
    description: 'Revived tracker with broad catalog',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'torrentdownload',
    name: 'Torrent Download',
    description: 'Clean search interface, good coverage',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  {
    id: 'bitsearch',
    name: 'Bitsearch',
    description: 'Modern aggregator with high seeders',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
]

export const DEFAULT_ENABLED_INDEXER_IDS = INDEXER_CATALOG.filter((e) => e.defaultEnabled).map(
  (e) => e.id
)

export function parseEnabledIndexerIDs(raw: string | null | undefined): Set<string> {
  const known = new Set(INDEXER_CATALOG.map((e) => e.id))
  if (!raw?.trim()) return new Set(DEFAULT_ENABLED_INDEXER_IDS)
  const ids = raw
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter((id) => known.has(id))
  return ids.size > 0 ? ids : new Set(DEFAULT_ENABLED_INDEXER_IDS)
}
