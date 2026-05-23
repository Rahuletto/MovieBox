/** https://subdl.com/api-doc — GET search, dl.subdl.com for archives / unpack files */
const SUBDL_API_BASE = 'https://api.subdl.com/api/v1/subtitles'
const SUBDL_DL_BASE = 'https://dl.subdl.com'
const SUBDL_MAX_SUBS_PER_PAGE = 30

const SUBDL_FETCH_HEADERS: Record<string, string> = {
  Accept: 'application/json',
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
}

const SUBDL_LANGUAGE_MAP: Record<string, string> = {
  all: 'EN',
  en: 'EN',
  english: 'EN',
  es: 'ES',
  spanish: 'ES',
  fr: 'FR',
  french: 'FR',
  de: 'DE',
  german: 'DE',
  pt: 'PT',
  portuguese: 'PT',
  ru: 'RU',
  russian: 'RU',
  ar: 'AR',
  arabic: 'AR',
  it: 'IT',
  italian: 'IT',
  nl: 'NL',
  dutch: 'NL',
  ko: 'KO',
  korean: 'KO',
  ja: 'JA',
  japanese: 'JA',
  zh: 'ZH',
  chinese: 'ZH',
  hi: 'HI',
  hindi: 'HI',
  tr: 'TR',
  turkish: 'TR',
}

export interface SubtitleResult {
  id: string
  name: string
  author: string
  language: string
  downloadUrl: string
}

interface SubdlUnpackFile {
  file_n_id?: string
  name?: string
  release_name?: string
  language?: string
  format?: string
  url?: string
  episode?: number
  season?: number
}

interface SubdlSubtitleRow {
  release_name?: string
  name?: string
  lang?: string
  author?: string
  url?: string
  download_link?: string
  language?: string
  unpack_files?: SubdlUnpackFile[]
  season?: number
  episode?: number
}

interface SubdlSearchResponse {
  status?: boolean
  subtitles?: SubdlSubtitleRow[]
  error?: string
  message?: string
}

export function mapSubdlLanguages(language: string | undefined): string {
  const key = (language ?? 'all').trim().toLowerCase()
  if (key === 'all' || key === '*') return 'EN,ES,FR,DE,PT'
  return SUBDL_LANGUAGE_MAP[key] ?? 'EN'
}

export class SubdlUpstreamError extends Error {
  readonly status: number

  constructor(status: number, message?: string) {
    super(message ?? `SubDL HTTP ${status}`)
    this.name = 'SubdlUpstreamError'
    this.status = status
  }
}

function pickUnpackFile(
  row: SubdlSubtitleRow,
  episodeNumber?: number | null
): SubdlUnpackFile | undefined {
  const files = row.unpack_files ?? []
  if (files.length === 0) return undefined

  const srtFiles = files.filter(
    (file) =>
      file.format?.toLowerCase() === 'srt' || file.name?.toLowerCase().endsWith('.srt')
  )
  const pool = srtFiles.length > 0 ? srtFiles : files

  if (episodeNumber != null) {
    const episodeMatch = pool.find((file) => file.episode === episodeNumber)
    if (episodeMatch) return episodeMatch
  }

  return pool[0]
}

function subdlDownloadURL(
  row: SubdlSubtitleRow,
  episodeNumber?: number | null
): string | null {
  const direct = row.download_link?.trim()
  if (direct) return toSubdlDownloadURL(direct)

  const unpackFile = pickUnpackFile(row, episodeNumber)
  if (unpackFile?.url?.trim()) return toSubdlDownloadURL(unpackFile.url)

  if (row.url?.trim()) return toSubdlDownloadURL(row.url)
  return null
}

function toSubdlDownloadURL(pathOrURL: string): string {
  const trimmed = pathOrURL.trim()
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return trimmed
  const path = trimmed.startsWith('/') ? trimmed : `/${trimmed}`
  return `${SUBDL_DL_BASE}${path}`
}

function normalizeImdbId(raw: string): string {
  const trimmed = raw.replace(/^tt/i, '').trim()
  return trimmed ? `tt${trimmed}` : raw
}

export async function searchSubdlSubtitles(options: {
  apiKey: string
  title?: string | null
  year?: number | null
  language?: string
  type: 'movie' | 'tv'
  imdbId?: string | null
  tmdbId?: number | null
  seasonNumber?: number | null
  episodeNumber?: number | null
}): Promise<SubtitleResult[]> {
  const params = new URLSearchParams()
  params.set('api_key', options.apiKey)
  params.set('type', options.type === 'tv' ? 'tv' : 'movie')
  params.set('languages', mapSubdlLanguages(options.language))
  params.set('subs_per_page', String(SUBDL_MAX_SUBS_PER_PAGE))
  params.set('unpack', '1')

  if (options.title?.trim()) params.set('film_name', options.title.trim())
  if (options.year) params.set('year', String(options.year))
  if (options.imdbId?.trim()) {
    params.set('imdb_id', normalizeImdbId(options.imdbId))
  }
  if (options.tmdbId && options.tmdbId > 0) params.set('tmdb_id', String(options.tmdbId))
  if (options.type === 'tv') {
    if (options.seasonNumber != null) params.set('season_number', String(options.seasonNumber))
    if (options.episodeNumber != null) params.set('episode_number', String(options.episodeNumber))
  }

  const url = `${SUBDL_API_BASE}?${params.toString()}`
  const response = await fetch(url, { headers: SUBDL_FETCH_HEADERS })

  if (!response.ok) {
    throw new SubdlUpstreamError(response.status)
  }

  const payload = (await response.json()) as SubdlSearchResponse
  if (payload.status === false) {
    return []
  }

  const rows = payload.subtitles ?? []
  const seen = new Set<string>()
  const results: SubtitleResult[] = []

  for (const row of rows) {
    const downloadUrl = subdlDownloadURL(row, options.episodeNumber)
    if (!downloadUrl) continue
    if (seen.has(downloadUrl)) continue
    seen.add(downloadUrl)

    const slug = row.url?.replace(/^\/subtitle\//, '') ?? downloadUrl
    const id = `subdl:${slug}`
    const name = (row.release_name || row.name || 'Subtitle').trim()
    const author = (row.author || 'SubDL').trim()
    const language = (row.lang || row.language || 'unknown').trim()

    results.push({
      id,
      name,
      author,
      language,
      downloadUrl,
    })
  }

  return results
}
