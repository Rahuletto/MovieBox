# Torrent Indexer Architecture & Expansion Guide

## Overview

The moviebox Backend uses a **pluggable indexer architecture** located in `Backend/src/torrent/`. Each indexer is responsible for searching a torrent source and returning normalized `TorrentSearchHit` results.

```diagram
┌─────────────────────────────────────────────────────────────┐
│                      Search Entry Point                      │
│                   searchAllTorrents(opts)                    │
└────────────────────────────┬────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │   Parse Query   │
                    │ (Season/Episode)│
                    └────────┬────────┘
                             │
            ┌────────────────┴────────────────┐
            │                                 │
   ┌────────▼────────┐          ┌────────────▼──────┐
   │ Main Search     │          │ Season Pack Search│
   │ (all indexers)  │          │ (TV only, parallel)
   └────────┬────────┘          └────────┬──────────┘
            │                            │
  ┌─────────▼─────────────────────────────▼──┐
  │  runIndexers(ctx, enabledIds)             │
  │  - Parallel execution (Promise.allSettled)│
  │  - 25s timeout per indexer                │
  │  - Dedup by infoHash (highest seeders)    │
  └──────────┬───────────────────────────────┘
             │
  ┌──────────▼────────────────────────────────┐
  │  Return TorrentSearchPayload               │
  │  - Merged results sorted by seeders        │
  │  - Per-indexer counts & errors             │
  └───────────────────────────────────────────┘
```

---

## Core Components

### 1. **types.ts** — Interface Definitions

```typescript
export interface TorrentIndexer {
  id: string                           // Unique ID (e.g., 'piratebay')
  displayName: string                  // UI-friendly name
  supports(ctx: SearchContext): boolean // Can this indexer handle this query?
  search(ctx: SearchContext): Promise<TorrentSearchHit[]>
}

export interface SearchContext {
  query: string                // Sanitized search query
  year: number | null          // Release year (optional)
  imdbId: string | null        // IMDb ID (for aggregators like Torrentio)
  kind: 'movie' | 'tv'         // Content type
  enableYTS: boolean           // YTS toggle
  season: number | null        // TV: parsed season number
  episode: number | null       // TV: parsed episode number
}

export interface TorrentSearchHit {
  title: string                // Torrent name
  magnetURI: string            // Full magnet link
  infoHash: string | null      // 40-char SHA1 hash (used for dedup)
  quality: string              // e.g., "1080p", "2160p"
  sizeBytes: number            // File size in bytes
  seeders: number              // Active seeders
  leechers: number             // Active leechers
  trackerSource: string        // e.g., "1337x", "Pirate Bay"
}
```

### 2. **catalog.ts** — Registration & Configuration

All indexers are registered in `INDEXER_CATALOG`:

```typescript
export const INDEXER_CATALOG: IndexerCatalogEntry[] = [
  {
    id: 'torrentio',
    name: 'Torrentio',
    description: 'Aggregator (needs IMDb id from metadata)',
    kinds: ['movie', 'tv'],
    defaultEnabled: true,
  },
  // ... more indexers
]
```

### 3. **registry.ts** — Execution Engine

- Imports all indexer implementations
- `runIndexers(ctx, enabledIds)`: Runs active indexers in parallel
  - 25-second timeout per indexer
  - `Promise.allSettled` for resilience
  - **Deduplication**: By `infoHash`, keeps entry with highest seeders
  - Results sorted by seeders (descending)

### 4. **utils.ts** — Shared Utilities

```typescript
fetchJSON<T>(url)              // Fetch & parse JSON with User-Agent
fetchHTML(url)                 // Fetch HTML with redirect following
magnetFor(hash, title)         // Generate magnet link with trackers
parseSizeBytes(text)           // "1.5 GB" → bytes
hashFromMagnet(magnet)         // Extract 40-char SHA1 from magnet
resolveQualityLabel(title)     // Infer 4K/1080p/720p from text
decodeHtml(text)               // Decode HTML entities
```

---

## Current Indexers

| ID | Source | Type | API/Scrape | Status |
|----|--------|------|-----------|--------|
| **torrentio** | Stremio | Aggregator | API | ✅ |
| **yts** | YTS | Movies | API + Mirrors | ✅ |
| **eztv** | EZTV | TV | API | ✅ |
| **piratebay** | Pirate Bay | Both | JSON API (apibay) | ✅ |
| **1337x** | 1337x | Both | HTML Scrape | ✅ |

---

## How to Add a New Indexer

### Step 1: Create the Indexer File

Create `Backend/src/torrent/indexers/{id}.ts`:

```typescript
import type { SearchContext, TorrentIndexer, TorrentSearchHit } from '../types'
import { fetchJSON, fetchHTML, magnetFor, resolveQualityLabel } from '../utils'

export const myIndexer: TorrentIndexer = {
  id: 'mysite',                    // Unique identifier
  displayName: 'My Site',          // User-facing name
  
  supports(ctx: SearchContext): boolean {
    // Return true if this indexer can handle this search
    // E.g., only movies: return ctx.kind === 'movie'
    // E.g., requires IMDb: return !!ctx.imdbId
    return true
  },
  
  async search(ctx: SearchContext): Promise<TorrentSearchHit[]> {
    // 1. Build search URL(s)
    const url = `https://api.mysite.com/search?q=${encodeURIComponent(ctx.query)}`
    
    // 2. Fetch data (JSON or HTML)
    const data = await fetchJSON(url)
    if (!data) return []
    
    // 3. Transform to TorrentSearchHit[] format
    return data.map(item => ({
      title: item.name,
      magnetURI: item.magnetLink || magnetFor(item.hash, item.name),
      infoHash: item.hash?.toLowerCase() || null,
      quality: resolveQualityLabel(item.quality, item.name),
      sizeBytes: item.size || 0,
      seeders: item.seeders || 0,
      leechers: item.leechers || 0,
      trackerSource: 'My Site',
    }))
  }
}
```

### Step 2: Register in `registry.ts`

```typescript
import { myIndexer } from './indexers/mysite'

export const INDEXERS: TorrentIndexer[] = [
  torrentioIndexer,
  ytsIndexer,
  eztvIndexer,
  pirateBayIndexer,
  x1337Indexer,
  myIndexer,  // ← Add here
]
```

### Step 3: Add to `catalog.ts`

```typescript
export const INDEXER_CATALOG: IndexerCatalogEntry[] = [
  // ... existing
  {
    id: 'mysite',
    name: 'My Site',
    description: 'Clear description of source',
    kinds: ['movie'] | ['tv'] | ['movie', 'tv'],
    defaultEnabled: true,  // Include in default searches
  },
]
```

### Step 4: Verify

Run tests:
```bash
cd Backend
pnpm test
```

---

## Recommended New Indexers

### High-Priority Additions

1. **RarBG** (deprecated but cached, fallback)
   - Alternative: RARBG API wrapper services
   - Source: apibg.com or similar
   - Type: JSON API
   - Content: Movies + TV (high quality)

2. **Nyaa (Anime)**
   - API: `https://api.nyaa.si/`
   - Type: JSON REST
   - Content: Anime torrents
   - Benefit: Dedicated anime source

3. **ProPublica**
   - Source: Torrentio already covers but direct access useful
   - Type: Hybrid (some use aggregators)

4. **Rutracker** (Russian tracker, but good coverage)
   - Type: HTML scraping
   - Content: Movies, TV, rare content

5. **GloTorrents** / **OHShit**
   - Type: JSON API
   - Low-friction indexing

### Integration Approaches

#### A. **JSON API-based** (Easiest)
```typescript
// Use fetchJSON + simple map/filter
const hits = await fetchJSON(`${url}?q=${query}`)
return hits.map(item => ({ /* normalize */ }))
```

#### B. **HTML Scraping** (Medium)
```typescript
// Use fetchHTML + regex parsing (like 1337x)
const html = await fetchHTML(url)
const matches = html.matchAll(/<tr>.*?<td>([^<]+)<\/td>.*?<\/tr>/g)
// Parse & extract title, hash, seeders, etc.
```

#### C. **Aggregator Integration** (Simplest)
```typescript
// Use existing Stremio/Torrentio-like APIs
// Example: Prowlarr, Jackett instances
// Benefit: Single integration = multiple sources
```

---

## Testing Strategy

### Unit Tests for New Indexer

```typescript
// Backend/tests/indexers/mysite.test.ts
import { describe, it, expect, vi } from 'vitest'
import { myIndexer } from '../../src/torrent/indexers/mysite'

describe('myIndexer', () => {
  it('should support movies', () => {
    expect(myIndexer.supports({ kind: 'movie', /* ... */ })).toBe(true)
  })
  
  it('should return TorrentSearchHit[] on valid search', async () => {
    const results = await myIndexer.search({
      query: 'Avatar',
      kind: 'movie',
      imdbId: null,
      year: 2022,
      season: null,
      episode: null,
      enableYTS: false
    })
    
    expect(Array.isArray(results)).toBe(true)
    expect(results.length).toBeGreaterThan(0)
    expect(results[0]).toHaveProperty('infoHash')
    expect(results[0]).toHaveProperty('magnetURI')
  })
})
```

### Integration Test

```typescript
import { searchAllTorrents } from '../../src/torrent/search'

const payload = await searchAllTorrents({
  query: 'Avatar 2022',
  kind: 'movie',
  enabledIndexerIDs: 'mysite',  // Test only your indexer
})

console.log(`Results: ${payload.results.length}`)
console.log(`My Site returned: ${payload.counts.mysite}`)
if (payload.errors.mysite) console.error(`Error: ${payload.errors.mysite}`)
```

---

## Debugging Tips

1. **Check if indexer is enabled**:
   - App may have user preferences hiding indexers
   - Check `enabledIndexerIDs` query param in API calls

2. **Test with cURL/Postman**:
   ```bash
   curl "http://localhost:3000/api/search?query=Avatar&kind=movie&enabledIndexerIDs=mysite"
   ```

3. **Add logging**:
   ```typescript
   console.log(`[mysite] Searching: ${ctx.query}`)
   console.log(`[mysite] Found ${results.length} results`)
   ```

4. **Timeout issues**: Increase `INDEXER_TIMEOUT_MS` (currently 25s) if indexer is too slow

5. **Deduplication check**: Ensure `infoHash` is 40-char SHA1 hex; otherwise results won't deduplicate

---

## Common Patterns

### Fallback Hosts

Like 1337x, use multiple mirrors:

```typescript
const hosts = ['https://host1.com', 'https://host2.com', 'https://host3.com']
for (const base of hosts) {
  const results = await searchHost(base, ctx.query)
  if (results.length) return results  // First successful host
}
return []
```

### Season/Episode Support

For TV shows, check `ctx.season` and `ctx.episode`:

```typescript
if (ctx.season !== null) {
  const seasonQuery = `${ctx.query} S${ctx.season.toString().padStart(2, '0')}`
  // Search season pack
}
```

### Quality Detection

Use `resolveQualityLabel()` to extract from title:

```typescript
resolveQualityLabel(item.quality, item.title)
// Automatically detects 4K, 1080p, 720p from text
```

---

## Performance Considerations

- **Parallel execution**: All enabled indexers run simultaneously (Promise.allSettled)
- **Timeout**: 25 seconds per indexer; slow sources get dropped
- **Caching**: `fetchJSON`/`fetchHTML` use Cloudflare Workers cache (300s TTL)
- **Deduplication**: O(n) by infoHash; prevents redundant results

---

## References

### Public Torrent APIs & Aggregators

- **Torrentio** (Stremio): `https://torrentio.stremio-addons.com/`
- **EZTV API**: `https://eztv.re/api/`
- **APIBay** (TPB): `https://apibay.org/`
- **Prowlarr**: Self-hosted aggregator
- **Jackett**: Self-hosted indexer proxy
- **Nyaa (Anime)**: `https://api.nyaa.si/`

### Scraping Resources

- **Common patterns**: HTML table parsing, magnet extraction
- **User-Agent rotation**: Use `utils.USER_AGENT` or rotate
- **Robots.txt**: Check before scraping; use APIs when available
- **Rate limiting**: Respect server load; cache aggressively

---

## Next Steps

1. **Pick 2–3 indexers** from the recommendations above
2. **Implement as new files** in `Backend/src/torrent/indexers/`
3. **Register** in `registry.ts` and `catalog.ts`
4. **Test** with `pnpm test` and manual API calls
5. **Merge** and deploy

Example prioritized additions:
1. **Nyaa** (anime audience gap)
2. **RarBG wrapper** (high-quality movies/TV)
3. **Direct Torrentio alternative** (redundancy for IMDb-based searches)
