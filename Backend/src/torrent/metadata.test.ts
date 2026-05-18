import { describe, expect, it } from 'vitest'
import { isTorrentFileBytes } from './metadata'

describe('isTorrentFileBytes', () => {
  it('accepts bencode dictionary prefix', () => {
    const torrent = new Uint8Array([0x64, 0x38, 0x3a, 0x61, 0x6e, 0x6e, 0x6f, 0x75, 0x6e, 0x63, 0x65])
    expect(isTorrentFileBytes(torrent)).toBe(true)
  })

  it('rejects HTML error pages', () => {
    const html = new TextEncoder().encode('<meta name="viewport" content="width=device-width">')
    expect(isTorrentFileBytes(html)).toBe(false)
  })

  it('rejects tiny payloads', () => {
    expect(isTorrentFileBytes(new Uint8Array(32))).toBe(false)
  })
})
