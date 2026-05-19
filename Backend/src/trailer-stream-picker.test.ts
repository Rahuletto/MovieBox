import { describe, expect, it } from 'vitest'
import { pickTrailerStreamURL } from './trailer-stream-picker'

describe('pickTrailerStreamURL', () => {
  it('prefers odycdn MP4 over proxy WebM', () => {
    const url = pickTrailerStreamURL({
      videoStreams: [
        {
          format: 'WEBM',
          quality: '2160',
          url: 'https://proxy.piped.private.coffee/videoplayback?mime=video/webm',
        },
        {
          format: 'MP4',
          quality: '720',
          url: 'https://player.odycdn.com/v6/streams/abc/720.mp4',
        },
        {
          format: 'MPEG_4',
          quality: '1080',
          url: 'https://proxy.piped.private.coffee/videoplayback?mime=video/mp4',
        },
      ],
    })
    expect(url).toContain('odycdn')
    expect(url).toContain('.mp4')
  })

  it('returns HLS when no direct MP4', () => {
    const url = pickTrailerStreamURL({
      hlsUrl: 'https://player.odycdn.com/v6/streams/abc/playlist.m3u8',
      videoStreams: [{ format: 'MP4', quality: '720', url: 'https://proxy.example/videoplayback' }],
    })
    expect(url).toContain('m3u8')
  })
})
