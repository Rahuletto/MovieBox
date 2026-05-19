import { afterEach, describe, expect, it, vi } from 'vitest'
import { resolveTrailerStreamURL } from './trailer-resolve'

describe('resolveTrailerStreamURL', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('returns MP4 URL from a working Piped instance', async () => {
    const mp4URL =
      'https://player.odycdn.com/v6/streams/example/7bb5db.mp4'

    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input)
        if (url.includes('piped-instances.kavin.rocks')) {
          return new Response(
            JSON.stringify([{ api_url: 'https://api.piped.private.coffee' }]),
            { status: 200, headers: { 'Content-Type': 'application/json' } }
          )
        }
        if (url.includes('/streams/testkey')) {
          return new Response(
            JSON.stringify({
              videoStreams: [{ url: mp4URL, format: 'MP4', quality: '720' }],
            }),
            { status: 200, headers: { 'Content-Type': 'application/json' } }
          )
        }
        return new Response('not found', { status: 404 })
      })
    )

    const url = await resolveTrailerStreamURL('testkey')
    expect(url).toBe(mp4URL)
  })

  it('returns null when every instance fails', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('error', { status: 502 }))
    )

    const url = await resolveTrailerStreamURL('testkey')
    expect(url).toBeNull()
  })
})
