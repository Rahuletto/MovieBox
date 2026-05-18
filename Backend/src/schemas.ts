import { z } from 'zod'

/** Shared media kind used across torrent + TMDB routes. */
export const MediaKindSchema = z.enum(['movie', 'tv'])
export type MediaKind = z.infer<typeof MediaKindSchema>

/** Numeric TMDB id path segment. */
export const TmdbIdParamSchema = z
  .string()
  .regex(/^\d+$/, 'id must be a numeric TMDB id')
  .transform((s) => s)

export const TitleRouteParamsSchema = z.object({
  kind: MediaKindSchema,
  id: TmdbIdParamSchema,
})

export const LogoRouteParamsSchema = TitleRouteParamsSchema

/** Info hash: 40 hex chars, optional urn prefix stripped by client. */
export const InfoHashQuerySchema = z.object({
  hash: z
    .string()
    .min(1)
    .transform((h) => h.trim().toLowerCase())
    .refine((h) => /^[a-f0-9]{40}$/.test(h), 'hash must be 40 hexadecimal characters'),
})

export const TorrentMetadataQuerySchema = z
  .object({
    hash: z.string().optional(),
    infoHash: z.string().optional(),
  })
  .transform(({ hash, infoHash }) => ({ hash: hash ?? infoHash }))
  .pipe(InfoHashQuerySchema)

const optionalYear = z
  .string()
  .optional()
  .transform((y) => {
    if (y === undefined || y === '') return null
    const n = Number.parseInt(y, 10)
    return Number.isFinite(n) ? n : null
  })

export const TorrentSearchQuerySchema = z.object({
  q: z.string().trim().min(1, 'q is required'),
  kind: z
    .string()
    .optional()
    .transform((k) => (k === 'tv' ? 'tv' : 'movie') as MediaKind),
  year: optionalYear,
  imdbId: z
    .string()
    .optional()
    .transform((id) => {
      if (!id?.trim()) return null
      return id.replace(/^tt/i, '').trim() || null
    }),
  enabled: z.string().optional(),
  indexers: z.string().optional(),
})

export const SubtitleSearchQuerySchema = z
  .object({
    title: z.string().optional(),
    year: z.string().optional(),
    language: z.string().optional().default('english'),
    type: z.enum(['movie', 'tv']).optional().default('movie'),
    imdb_id: z.string().optional(),
  })
  .refine((q) => Boolean(q.title?.trim() || q.imdb_id?.trim()), {
    message: 'title or imdb_id is required',
  })

export const SubtitleDownloadQuerySchema = z.object({
  url: z.string().trim().min(1, 'url is required'),
})

export const TrailerResolveQuerySchema = z.object({
  key: z
    .string()
    .trim()
    .min(1, 'key is required')
    .max(32, 'key is too long'),
})

export const ImageProxyQuerySchema = z.object({
  u: z.string().url('u must be a valid absolute URL'),
})

export const PipedStreamResponseSchema = z.object({
  hls: z.string().url().optional(),
  hlsUrl: z.string().url().optional(),
  videoStreams: z
    .array(
      z.object({
        url: z.string().url().optional(),
        format: z.string().optional(),
      })
    )
    .optional(),
})

export type TorrentSearchQuery = z.infer<typeof TorrentSearchQuerySchema>
export type SubtitleSearchQuery = z.infer<typeof SubtitleSearchQuerySchema>
