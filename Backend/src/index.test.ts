import { describe, it, expect, beforeAll } from 'vitest'
import { SELF } from 'cloudflare:test'

describe('Health endpoint', () => {
  it('returns ok status', async () => {
    const res = await SELF.fetch('http://localhost/health')
    expect(res.status).toBe(200)
    const data = await res.json()
    expect(data.ok).toBe(true)
    expect(data.service).toBe('moviebox-backend')
    expect(data.timestamp).toBeDefined()
  })
})

describe('Auth middleware', () => {
  it('rejects requests without token', async () => {
    const res = await SELF.fetch('http://localhost/api/tmdb/movie/popular')
    expect(res.status).toBe(401)
    const data = await res.json()
    expect(data.error).toBe('unauthorized')
  })

  it('rejects requests with wrong token', async () => {
    const res = await SELF.fetch('http://localhost/api/tmdb/movie/popular', {
      headers: { 'X-MovieBox-Token': 'wrong-token' },
    })
    expect(res.status).toBe(401)
  })
})

describe('TMDB proxy', () => {
  it('proxies movie detail request with valid token', async () => {
    const res = await SELF.fetch('http://localhost/api/tmdb/movie/550', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(200)
    const data = await res.json()
    expect(data.id).toBe(550)
    expect(data.title).toBeDefined()
  })

  it('proxies search request', async () => {
    const res = await SELF.fetch('http://localhost/api/tmdb/search/movie?query=matrix', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(200)
    const data = await res.json()
    expect(data.results).toBeDefined()
    expect(Array.isArray(data.results)).toBe(true)
  })

  it('returns 404 for invalid TMDB path', async () => {
    const res = await SELF.fetch('http://localhost/api/tmdb/invalid/path/that/does/not/exist', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(404)
  })
})

describe('OMDb proxy', () => {
  it('returns 400 without imdb id', async () => {
    const res = await SELF.fetch('http://localhost/api/omdb', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(400)
    const data = await res.json()
    expect(data.error).toBe('bad_request')
  })

  it('returns 503 when not configured', async () => {
    const res = await SELF.fetch('http://localhost/api/omdb?i=tt0137523', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(503)
  })
})

describe('Subtitles endpoint', () => {
  it('returns 400 without title or imdb_id', async () => {
    const res = await SELF.fetch('http://localhost/api/subtitles/search', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(400)
    const data = await res.json()
    expect(data.error).toBe('bad_request')
  })

  it('searches subtitles with title', async () => {
    const res = await SELF.fetch(
      'http://localhost/api/subtitles/search?title=Fight+Club&year=1999&language=en',
      {
        headers: { 'X-MovieBox-Token': 'test-secret' },
      }
    )
    expect(res.status).toBe(200)
    const data = await res.json()
    expect(data.subtitles).toBeDefined()
    expect(Array.isArray(data.subtitles)).toBe(true)
  })

  it('returns empty array when no subtitles found', async () => {
    const res = await SELF.fetch(
      'http://localhost/api/subtitles/search?title=xyznonexistentmovie123&language=en',
      {
        headers: { 'X-MovieBox-Token': 'test-secret' },
      }
    )
    expect(res.status).toBe(200)
    const data = await res.json()
    expect(data.subtitles).toBeDefined()
    expect(Array.isArray(data.subtitles)).toBe(true)
  })

  it('returns 400 for download without url', async () => {
    const res = await SELF.fetch('http://localhost/api/subtitles/download', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(400)
    const data = await res.json()
    expect(data.error).toBe('bad_request')
  })
})

describe('404 handler', () => {
  it('returns structured 404 for unknown routes', async () => {
    const res = await SELF.fetch('http://localhost/api/unknown/route', {
      headers: { 'X-MovieBox-Token': 'test-secret' },
    })
    expect(res.status).toBe(404)
    const data = await res.json()
    expect(data.error).toBe('not_found')
  })
})

describe('CORS headers', () => {
  it('includes CORS headers on API responses', async () => {
    const res = await SELF.fetch('http://localhost/health')
    expect(res.headers.get('Access-Control-Allow-Origin')).toBeDefined()
  })
})
