import { z } from 'zod'

/** TMDB external_ids payload (subset used by logo/title enrichment). */
export const TMDBExternalIdsSchema = z.object({
  imdb_id: z.string().nullable().optional(),
  tvdb_id: z.number().nullable().optional(),
})

export type TMDBExternalIds = z.infer<typeof TMDBExternalIdsSchema>

/** Brief title fields used when resolving Fanart/OMDB fallbacks. */
export const TMDBTitleBriefSchema = z
  .object({
    id: z.number().optional(),
    title: z.string().optional(),
    name: z.string().optional(),
    release_date: z.string().optional(),
    first_air_date: z.string().optional(),
    runtime: z.number().optional(),
    external_ids: TMDBExternalIdsSchema.optional(),
  })
  .passthrough()

export type TMDBTitleBrief = z.infer<typeof TMDBTitleBriefSchema>

/** Title bundle detail from TMDB append_to_response (validated subset + passthrough). */
export const TMDBTitleDetailSchema = TMDBTitleBriefSchema.extend({
  overview: z.string().optional(),
}).passthrough()

export type TMDBTitleDetailParsed = z.infer<typeof TMDBTitleDetailSchema>

const tmdbJsonValue: z.ZodType<unknown> = z.lazy(() =>
  z.union([
    z.string(),
    z.number(),
    z.boolean(),
    z.null(),
    z.array(tmdbJsonValue),
    z.record(z.string(), tmdbJsonValue),
  ])
)

/** Any JSON object/array returned by the TMDB proxy. */
export const TmdbProxyResponseSchema = tmdbJsonValue

export function parseTmdbJson(data: unknown): unknown {
  const parsed = TmdbProxyResponseSchema.safeParse(data)
  if (!parsed.success) {
    throw new Error('invalid TMDB JSON payload')
  }
  return parsed.data
}
