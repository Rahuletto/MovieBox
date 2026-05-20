import { describe, expect, it } from 'vitest'
import { pickTrailerStreamURL } from './trailer-stream-picker'

describe('pickTrailerStreamURL', () => {
  it('prefers odycdn MP4 over proxy WebM', () => {
    const url = pickTrailerStreamURL({
      videoStreams: [
        {
          format: 'WEBM',
          quality: '2160p',
          videoOnly: true,
          url: 'https://proxy.piped.private.coffee/videoplayback?mime=video/webm',
        },
        {
          format: 'MP4',
          quality: '720',
          videoOnly: false,
          url: 'https://player.odycdn.com/v6/streams/abc/720.mp4',
        },
        {
          format: 'MPEG_4',
          quality: '1080p',
          videoOnly: true,
          url: 'https://proxy.piped.private.coffee/videoplayback?mime=video/mp4&itag=137',
        },
      ],
    })
    expect(url).toContain('odycdn')
    expect(url).toContain('.mp4')
  })

  it('prefers muxed proxy MPEG over video-only proxy (itag 137)', () => {
    const url = pickTrailerStreamURL({
      videoStreams: [
        {
          format: 'MPEG_4',
          quality: '1080p',
          videoOnly: true,
          url: 'https://proxy.piped.private.coffee/videoplayback?itag=137',
        },
        {
          format: 'MPEG_4',
          quality: '360p',
          videoOnly: false,
          url: 'https://proxy.piped.private.coffee/videoplayback?itag=18',
        },
      ],
    })
    expect(url).toContain('itag=18')
    expect(url).not.toContain('itag=137')
  })

  it('returns null when only video-only proxy streams exist', () => {
    const url = pickTrailerStreamURL({
      videoStreams: [
        {
          format: 'MPEG_4',
          quality: '1080p',
          videoOnly: true,
          url: 'https://proxy.piped.private.coffee/videoplayback?itag=137',
        },
        {
          format: 'WEBM',
          quality: '1080p',
          videoOnly: true,
          url: 'https://proxy.piped.private.coffee/videoplayback?mime=video/webm',
        },
      ],
    })
    expect(url).toBeNull()
  })

  it('returns odycdn HLS when no MP4', () => {
    const url = pickTrailerStreamURL({
      hlsUrl: 'https://player.odycdn.com/v6/streams/abc/playlist.m3u8',
      videoStreams: [
        {
          format: 'MPEG_4',
          quality: '720',
          videoOnly: true,
          url: 'https://proxy.example/videoplayback',
        },
      ],
    })
    expect(url).toContain('m3u8')
  })
})
