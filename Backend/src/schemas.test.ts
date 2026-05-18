import { describe, expect, it } from 'vitest'
import {
  InfoHashQuerySchema,
  MediaKindSchema,
  TorrentSearchQuerySchema,
  TrailerResolveQuerySchema,
  TitleRouteParamsSchema,
} from './schemas'
import { parseSchema } from './validate'

describe('MediaKindSchema', () => {
  it('accepts movie and tv', () => {
    expect(MediaKindSchema.parse('movie')).toBe('movie')
    expect(MediaKindSchema.parse('tv')).toBe('tv')
  })

  it('rejects unknown kinds', () => {
    expect(MediaKindSchema.safeParse('anime').success).toBe(false)
  })
})

describe('TitleRouteParamsSchema', () => {
  it('requires numeric id', () => {
    const ok = TitleRouteParamsSchema.safeParse({ kind: 'movie', id: '550' })
    expect(ok.success).toBe(true)
    const bad = TitleRouteParamsSchema.safeParse({ kind: 'movie', id: 'abc' })
    expect(bad.success).toBe(false)
  })
})

describe('InfoHashQuerySchema', () => {
  it('validates 40-char hex hash', () => {
    const hash = 'a'.repeat(40)
    expect(InfoHashQuerySchema.parse({ hash }).hash).toBe(hash)
  })

  it('rejects short hash', () => {
    expect(InfoHashQuerySchema.safeParse({ hash: 'abc' }).success).toBe(false)
  })
})

describe('TorrentSearchQuerySchema', () => {
  it('normalizes kind and imdb id', () => {
    const data = TorrentSearchQuerySchema.parse({
      q: 'Inception',
      kind: 'tv',
      imdbId: 'tt1375666',
      year: '2010',
    })
    expect(data.kind).toBe('tv')
    expect(data.imdbId).toBe('1375666')
    expect(data.year).toBe(2010)
  })
})

describe('TrailerResolveQuerySchema', () => {
  it('requires non-empty key', () => {
    expect(TrailerResolveQuerySchema.safeParse({ key: '' }).success).toBe(false)
    expect(TrailerResolveQuerySchema.safeParse({ key: 'dQw4w9WgXcQ' }).success).toBe(true)
  })
})

describe('parseSchema', () => {
  it('returns structured error message', () => {
    const result = parseSchema(TorrentSearchQuerySchema, { q: '' })
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.message).toContain('q')
    }
  })
})
