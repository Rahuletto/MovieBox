import type { AppContext } from './context'
import {
  LOGO_TTL_HIT,
  LOGO_TTL_MISS,
  fetchFanart,
  fetchOmdbById,
  fetchOmdbByTitle,
  findOmdbRating,
  parseOmdbFloat,
  parseOmdbInt,
  parseOmdbRuntime,
  pickBestLogo,
  proxyImage,
  type ExternalIds,
  type FanartResponse,
  type OmdbResponse,
} from './logo'
import { kvPut } from './kv-cache'
import {
  buildRottenTomatoesStatsFromOmdb,
  fetchRottenTomatoesBundle,
  type RottenTomatoesStats,
} from './rotten-tomatoes'

export type MovieboxEnrichment = {
  imdb_rating: number | null
  imdb_votes: number | null
  metascore: number | null
  rotten_tomatoes: number | null
  rotten_tomatoes_stats: RottenTomatoesStats | null
  runtime_min: number | null
  rated: string | null
  released: string | null
  director: string | null
  writer: string | null
  actors: string | null
  awards: string | null
  country: string | null
  language: string | null
  box_office: string | null
  production: string | null
  genre: string | null
}

export type TitleBundle = TMDBTitleDetail & {
  moviebox_logo?: string | null
  moviebox_trailer_rt_hls?: string
  moviebox_enrichment?: MovieboxEnrichment
}

export type FanartTarget = {
  fanartKind: 'movies' | 'tv'
  externalId: string
}

export function resolveFanartTarget(
  kind: 'movie' | 'tv',
  extIds: ExternalIds,
  omdb: OmdbResponse | null
): FanartTarget | null {
  if (kind === 'tv' && extIds.tvdb_id) {
    return { fanartKind: 'tv', externalId: extIds.tvdb_id }
  }
  if (extIds.imdb_id) {
    return { fanartKind: kind === 'movie' ? 'movies' : 'tv', externalId: extIds.imdb_id }
  }
  if (omdb?.Response === 'True' && omdb.imdbID) {
    return { fanartKind: kind === 'movie' ? 'movies' : 'tv', externalId: omdb.imdbID }
  }
  return null
}

export type TMDBTitleDetail = Record<string, unknown> & {
  id?: number
  title?: string
  name?: string
  overview?: string
  release_date?: string
  first_air_date?: string
  runtime?: number
  external_ids?: ExternalIds
}

function readTitleFields(detail: TMDBTitleDetail): {
  extIds: ExternalIds
  title?: string
  year: string | null
} {
  const extIds = (detail.external_ids as ExternalIds | undefined) ?? {}
  const title =
    (typeof detail.title === 'string' ? detail.title : undefined) ??
    (typeof detail.name === 'string' ? detail.name : undefined)
  const year =
    ((detail.release_date as string | undefined) ??
      (detail.first_air_date as string | undefined) ??
      '')
      .toString()
      .slice(0, 4) || null
  return { extIds, title, year }
}

function buildEnrichment(
  omdb: OmdbResponse | null,
  rtStats: RottenTomatoesStats | null
): MovieboxEnrichment | null {
  const omdbOk = omdb?.Response === 'True'
  const omdbRuntime = omdbOk ? parseOmdbRuntime(omdb.Runtime) : null
  const omdbRtPercent = omdbOk ? findOmdbRating(omdb.Ratings, 'Rotten Tomatoes') : null
  const stats = rtStats ?? buildRottenTomatoesStatsFromOmdb(omdbRtPercent)
  if (!omdbOk && !stats) return null

  return {
    imdb_rating: omdbOk ? parseOmdbFloat(omdb.imdbRating) : null,
    imdb_votes: omdbOk ? parseOmdbInt(omdb.imdbVotes) : null,
    metascore: omdbOk ? parseOmdbInt(omdb.Metascore) : null,
    rotten_tomatoes: stats?.percentage ?? omdbRtPercent,
    rotten_tomatoes_stats: stats,
    runtime_min: omdbRuntime,
    rated: omdbOk && omdb.Rated && omdb.Rated !== 'N/A' ? omdb.Rated : null,
    released: omdbOk && omdb.Released && omdb.Released !== 'N/A' ? omdb.Released : null,
    director: omdbOk && omdb.Director && omdb.Director !== 'N/A' ? omdb.Director : null,
    writer: omdbOk && omdb.Writer && omdb.Writer !== 'N/A' ? omdb.Writer : null,
    actors: omdbOk && omdb.Actors && omdb.Actors !== 'N/A' ? omdb.Actors : null,
    awards: omdbOk && omdb.Awards && omdb.Awards !== 'N/A' ? omdb.Awards : null,
    country: omdbOk && omdb.Country && omdb.Country !== 'N/A' ? omdb.Country : null,
    language: omdbOk && omdb.Language && omdb.Language !== 'N/A' ? omdb.Language : null,
    box_office: omdbOk && omdb.BoxOffice && omdb.BoxOffice !== 'N/A' ? omdb.BoxOffice : null,
    production: omdbOk && omdb.Production && omdb.Production !== 'N/A' ? omdb.Production : null,
    genre: omdbOk && omdb.Genre && omdb.Genre !== 'N/A' ? omdb.Genre : null,
  }
}

export async function enrichTitleBundle(
  c: AppContext,
  detail: TMDBTitleDetail,
  kind: 'movie' | 'tv',
  id: string
): Promise<TitleBundle> {
  const { extIds, title, year } = readTitleFields(detail)

  const omdbTask: Promise<OmdbResponse | null> = (async () => {
    if (!c.env.OMDB_API_KEY) return null
    if (extIds.imdb_id) return fetchOmdbById(c, extIds.imdb_id)
    if (!title) return null
    return fetchOmdbByTitle(c, title, year, kind === 'movie' ? 'movie' : 'series')
  })()

  const rtTask = title
    ? fetchRottenTomatoesBundle(c.env.MOVIEBOX_CACHE, {
        kind: kind === 'movie' ? 'movie' : 'tv',
        title,
        year,
        imdbId: extIds.imdb_id ?? null,
      })
    : Promise.resolve({ stats: null, trailerHls: null })

  const [omdb, rtBundle] = await Promise.all([omdbTask, rtTask])
  const fanartTarget = resolveFanartTarget(kind, extIds, omdb)
  const fanart: FanartResponse | null =
    fanartTarget && c.env.FANART_API_KEY
      ? await fetchFanart(c, fanartTarget.fanartKind, fanartTarget.externalId)
      : null
  const omdbImdbId = extIds.imdb_id ?? (omdb?.Response === 'True' ? (omdb.imdbID ?? null) : null)
  const logoUrl = fanart ? pickBestLogo(fanart) : null
  const proxiedLogo = proxyImage(c, logoUrl)

  await kvPut(c.env.MOVIEBOX_CACHE, `logo:${kind}:${id}`, JSON.stringify({ url: proxiedLogo }), {
    expirationTtl: logoUrl ? LOGO_TTL_HIT : LOGO_TTL_MISS,
  })

  const bundle: TitleBundle = { ...detail, moviebox_logo: proxiedLogo }

  if (rtBundle.trailerHls) {
    bundle.moviebox_trailer_rt_hls = rtBundle.trailerHls
  }

  const enrichment = buildEnrichment(omdb, rtBundle.stats)
  if (enrichment) {
    bundle.moviebox_enrichment = enrichment
    if (!bundle.runtime && enrichment.runtime_min) {
      bundle.runtime = enrichment.runtime_min
    }
    if (
      omdb?.Response === 'True' &&
      (typeof bundle.overview !== 'string' || !bundle.overview.trim()) &&
      omdb.Plot &&
      omdb.Plot !== 'N/A'
    ) {
      bundle.overview = omdb.Plot
    }
    if (!extIds.imdb_id && omdbImdbId) {
      bundle.external_ids = {
        ...(bundle.external_ids as Record<string, unknown> | undefined),
        imdb_id: omdbImdbId,
      }
    }
  }

  return bundle
}
