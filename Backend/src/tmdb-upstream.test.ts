import { describe, expect, it } from 'vitest'
import { buildTMDBUpstreamURL, tmdbPathFromRequest } from './tmdb-upstream'

describe('tmdb-upstream', () => {
  it('maps worker path to TMDB v3 URL preserving query', () => {
    const url = buildTMDBUpstreamURL(
      'https://moviebox-backend.example.workers.dev/api/tmdb/movie/popular?page=2',
      '/movie/popular'
    )
    expect(url).toBe('https://api.themoviedb.org/3/movie/popular?page=2')
  })

  it('strips /api/tmdb prefix from request path', () => {
    expect(tmdbPathFromRequest('/api/tmdb/trending/movie/week')).toBe('/trending/movie/week')
  })
})
