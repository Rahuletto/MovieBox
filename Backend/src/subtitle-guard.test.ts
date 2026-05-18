import { describe, expect, it } from 'vitest'
import { assertSafeSubtitleURL, buildSubf2mURL } from './subtitle-guard'

describe('subtitle-guard', () => {
  it('allows subf2m paths', () => {
    const url = buildSubf2mURL('/subtitles/download/123')
    expect(url.hostname).toBe('subf2m.co')
  })

  it('blocks private hosts', () => {
    expect(() => assertSafeSubtitleURL('https://127.0.0.1/subtitles')).toThrow(
      'private_host_blocked'
    )
    expect(() => assertSafeSubtitleURL('https://192.168.0.1/subtitles')).toThrow(
      'private_host_blocked'
    )
  })

  it('blocks unknown hosts', () => {
    expect(() => assertSafeSubtitleURL('https://evil.example/subtitles')).toThrow(
      'host_not_allowed'
    )
  })
})
