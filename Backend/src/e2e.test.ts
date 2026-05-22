/**
 * End-to-end backend test — exercises the *real* torrent flow against a live
 * Worker (local dev by default, configurable via MOVIEBOX_WORKER_URL).
 *
 *   - Search torrents for Interstellar (movie)         → assert real seeded results
 *   - Fetch .torrent metadata for the top seeded hash  → assert valid bencoded payload
 *   - Search torrents for Breaking Bad S01E01 (tv)     → assert real seeded results
 *   - Fetch .torrent metadata for the top seeded hash  → assert valid bencoded payload
 *
 * Run:
 *   bun run dev        # in another terminal
 *   bun run test       # default MOVIEBOX_WORKER_URL=http://127.0.0.1:8787
 *
 *   # or against production:
 *   MOVIEBOX_WORKER_URL=https://moviebox-backend.rahulmarban.workers.dev bun run test
 */

import { readFileSync } from 'node:fs'
import { describe, it, expect, beforeAll } from 'vitest'

const BASE_URL = (process.env.MOVIEBOX_WORKER_URL ?? 'http://127.0.0.1:8787').replace(/\/+$/, '')

function loadDevVar(name: string): string | undefined {
  if (process.env[name]) return process.env[name]
  try {
    for (const line of readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8').split('\n')) {
      const trimmed = line.trim()
      if (!trimmed || trimmed.startsWith('#')) continue
      const i = trimmed.indexOf('=')
      if (i === -1) continue
      const key = trimmed.slice(0, i).trim()
      const value = trimmed.slice(i + 1).trim()
      if (key === name) return value
    }
  } catch {
    /* file missing — caller will fail with a clear message */
  }
  return undefined
}

const APP_SECRET = loadDevVar('APP_SECRET') ?? ''
const AUTH_HEADERS = { 'X-MovieBox-Token': APP_SECRET }

const SEARCH_TIMEOUT_MS = 60_000
const METADATA_TIMEOUT_MS = 90_000

type TorrentRow = {
  title: string
  magnetURI: string
  infoHash: string | null
  seeders: number
  leechers: number
  sizeBytes: number
  quality: string
  trackerSource?: { name?: string } | string
}

type SearchPayload = { results: TorrentRow[]; diagnostics?: unknown }

async function fetchJson<T>(path: string, init?: RequestInit): Promise<{ status: number; data: T }> {
  const url = path.startsWith('http') ? path : `${BASE_URL}${path}`
  const res = await fetch(url, {
    ...init,
    headers: { ...(init?.headers ?? {}), ...AUTH_HEADERS },
  })
  const text = await res.text()
  let data: T
  try {
    data = JSON.parse(text) as T
  } catch {
    throw new Error(
      `Non-JSON response from ${url} (status=${res.status}): ${text.slice(0, 300)}`
    )
  }
  return { status: res.status, data }
}

async function search(params: Record<string, string>): Promise<TorrentRow[]> {
  const qs = new URLSearchParams(params).toString()
  const { status, data } = await fetchJson<SearchPayload>(`/api/torrent/search?${qs}`)
  if (status !== 200) {
    throw new Error(`/api/torrent/search returned ${status}: ${JSON.stringify(data).slice(0, 300)}`)
  }
  return data.results ?? []
}

function pickTopSeededWithHash(rows: TorrentRow[]): TorrentRow {
  const seeded = rows
    .filter((r) => typeof r.infoHash === 'string' && /^[a-f0-9]{40}$/i.test(r.infoHash))
    .filter((r) => r.seeders > 0)
    .sort((a, b) => b.seeders - a.seeders)
  if (seeded.length === 0) {
    throw new Error(
      `No seeded torrents with valid infoHash in ${rows.length} results. ` +
        `First few: ${JSON.stringify(rows.slice(0, 3))}`
    )
  }
  return seeded[0]!
}

function summarize(row: TorrentRow): string {
  const size = (row.sizeBytes / (1024 * 1024 * 1024)).toFixed(2)
  return `${row.title} [${row.quality}, ${size} GiB, S=${row.seeders} L=${row.leechers}, hash=${row.infoHash?.slice(0, 8)}…]`
}

beforeAll(() => {
  if (!APP_SECRET) {
    throw new Error(
      'APP_SECRET is missing. Put it in Backend/.dev.vars or export APP_SECRET before running tests.'
    )
  }
})

describe('E2E backend health', () => {
  it('responds to /health with ok', async () => {
    const { status, data } = await fetchJson<{ ok: boolean; service: string }>('/health')
    expect(status).toBe(200)
    expect(data.ok).toBe(true)
    expect(data.service).toBe('moviebox-backend')
  }, 15_000)
})

describe('E2E movie torrent flow: Interstellar (2014)', () => {
  let top: TorrentRow

  it(
    'returns real seeded torrents for Interstellar',
    async () => {
      const rows = await search({
        q: 'Interstellar',
        year: '2014',
        kind: 'movie',
        imdbId: 'tt0816692',
      })
      console.log(`[interstellar] received ${rows.length} torrents`)
      expect(rows.length).toBeGreaterThan(0)
      top = pickTopSeededWithHash(rows)
      console.log(`[interstellar] top = ${summarize(top)}`)
      expect(top.magnetURI).toMatch(/^magnet:\?/i)
      expect(top.sizeBytes).toBeGreaterThan(50 * 1024 * 1024) // > 50 MB
      expect(top.seeders).toBeGreaterThan(0)
    },
    SEARCH_TIMEOUT_MS
  )

  it(
    'fetches a valid bencoded .torrent for the top seeded result',
    async () => {
      expect(top).toBeDefined()
      const url = `${BASE_URL}/api/torrent/metadata?hash=${top.infoHash}`
      const res = await fetch(url, { headers: AUTH_HEADERS })
      expect(res.status, `metadata fetch failed for ${top.infoHash}`).toBe(200)
      expect(res.headers.get('content-type') ?? '').toMatch(/application\/x-bittorrent/)
      const bytes = new Uint8Array(await res.arrayBuffer())
      console.log(`[interstellar] .torrent payload bytes=${bytes.length}`)
      // bencoded dict: starts with 'd' (0x64), ends with 'e' (0x65)
      expect(bytes.length).toBeGreaterThan(1024)
      expect(bytes[0]).toBe(0x64) // 'd'
      expect(bytes[bytes.length - 1]).toBe(0x65) // 'e'
      // info dict must be present (key length-prefixed: "4:info") somewhere in the payload
      const decoded = new TextDecoder('latin1').decode(bytes)
      expect(decoded).toMatch(/4:info/)
      expect(decoded).toMatch(/6:pieces/)
      expect(decoded).toMatch(/12:piece length/)
    },
    METADATA_TIMEOUT_MS
  )
})

describe('E2E tv torrent flow: Breaking Bad S01E01', () => {
  let top: TorrentRow

  it(
    'returns real seeded torrents for Breaking Bad S01E01',
    async () => {
      const rows = await search({
        q: 'Breaking Bad S01E01',
        kind: 'tv',
        imdbId: 'tt0903747',
      })
      console.log(`[breakingbad] received ${rows.length} torrents`)
      expect(rows.length).toBeGreaterThan(0)
      top = pickTopSeededWithHash(rows)
      console.log(`[breakingbad] top = ${summarize(top)}`)
      expect(top.magnetURI).toMatch(/^magnet:\?/i)
      expect(top.seeders).toBeGreaterThan(0)
      // S01E01 file/release size is typically 100 MB – 5 GB
      expect(top.sizeBytes).toBeGreaterThan(20 * 1024 * 1024)
    },
    SEARCH_TIMEOUT_MS
  )

  it(
    'fetches a valid bencoded .torrent for the top seeded result',
    async () => {
      expect(top).toBeDefined()
      const url = `${BASE_URL}/api/torrent/metadata?hash=${top.infoHash}`
      const res = await fetch(url, { headers: AUTH_HEADERS })
      expect(res.status, `metadata fetch failed for ${top.infoHash}`).toBe(200)
      expect(res.headers.get('content-type') ?? '').toMatch(/application\/x-bittorrent/)
      const bytes = new Uint8Array(await res.arrayBuffer())
      console.log(`[breakingbad] .torrent payload bytes=${bytes.length}`)
      expect(bytes.length).toBeGreaterThan(1024)
      expect(bytes[0]).toBe(0x64)
      expect(bytes[bytes.length - 1]).toBe(0x65)
      const decoded = new TextDecoder('latin1').decode(bytes)
      expect(decoded).toMatch(/4:info/)
      expect(decoded).toMatch(/6:pieces/)
      expect(decoded).toMatch(/12:piece length/)
    },
    METADATA_TIMEOUT_MS
  )
})
