import { describe, expect, it } from 'vitest'
import { parseEnabledIndexerIDs, DEFAULT_ENABLED_INDEXER_IDS } from './catalog'

describe('parseEnabledIndexerIDs', () => {
  it('returns default enabled indexers if raw is null or undefined', () => {
    expect(parseEnabledIndexerIDs(null)).toEqual(new Set(DEFAULT_ENABLED_INDEXER_IDS))
    expect(parseEnabledIndexerIDs(undefined)).toEqual(new Set(DEFAULT_ENABLED_INDEXER_IDS))
  })

  it('returns empty set (all disabled) for explicit empty string or whitespace', () => {
    expect(parseEnabledIndexerIDs('')).toEqual(new Set())
    expect(parseEnabledIndexerIDs('   ')).toEqual(new Set())
  })

  it('normalizes spaces and case, filtering out unknown indexers', () => {
    expect(parseEnabledIndexerIDs('YTS, eztv, InvalidIndexer')).toEqual(new Set(['yts', 'eztv']))
  })

  it('handles a valid single indexer ID', () => {
    expect(parseEnabledIndexerIDs('torrentio')).toEqual(new Set(['torrentio']))
  })
})
