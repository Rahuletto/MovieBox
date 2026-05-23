#!/usr/bin/env node
/**
 * Smoke-test all MovieBox Worker endpoints the macOS app uses.
 *
 * Usage (from Backend/):
 *   node scripts/smoke-worker.mjs
 *   MOVIEBOX_WORKER_URL=http://127.0.0.1:8787 node scripts/smoke-worker.mjs
 *   APP_SECRET=xxx node scripts/smoke-worker.mjs   # overrides .dev.vars
 *
 * Reads APP_SECRET from .dev.vars when not set in the environment.
 */

import { execSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const backendRoot = join(__dirname, '..')

const DEFAULT_BASE = 'https://moviebox-backend.rahulmarban.workers.dev'
const SAMPLE_MOVIE_ID = '550' // Fight Club
const SAMPLE_IMDB = 'tt0137523'
const TIMEOUT_MS = 25_000

function printProxyHint() {
  try {
    const pac = execSync('scutil --proxy 2>/dev/null | grep -E "ProxyAutoConfig|HTTPProxy|HTTPSProxy" || true', {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    if (pac) {
      console.log('System proxy (scutil):')
      for (const line of pac.split('\n')) console.log(`  ${line}`)
      console.log('')
    }
  } catch {
    /* not macOS */
  }
}

/** Fallback when Node fetch fails (PAC / TLS quirks). */
function curlRequest(url, token) {
  const args = ['-sS', '--max-time', String(Math.ceil(TIMEOUT_MS / 1000)), '-w', '\n%{http_code}']
  if (token) args.push('-H', `X-MovieBox-Token: ${token}`)
  args.push(url)
  try {
    const raw = execSync(`/usr/bin/curl ${args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(' ')}`, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: '/bin/bash',
    })
    const lines = raw.trimEnd().split('\n')
    const status = Number.parseInt(lines.at(-1) ?? '0', 10)
    const body = lines.slice(0, -1).join('\n')
    return { status, body }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return { status: 0, body: '', error: msg }
  }
}

function loadDevVars() {
  try {
    const text = readFileSync(join(backendRoot, '.dev.vars'), 'utf8')
    const out = {}
    for (const line of text.split('\n')) {
      const t = line.trim()
      if (!t || t.startsWith('#')) continue
      const i = t.indexOf('=')
      if (i === -1) continue
      out[t.slice(0, i).trim()] = t.slice(i + 1).trim()
    }
    return out
  } catch {
    return {}
  }
}

function trimBase(url) {
  return url.replace(/\/+$/, '')
}

const LOCAL_DEV_URL = 'http://127.0.0.1:8787'

async function isLocalDevReachable() {
  try {
    const res = await fetch(`${LOCAL_DEV_URL}/health`, {
      signal: AbortSignal.timeout(2500),
    })
    return res.ok
  } catch {
    return false
  }
}

function printUnreachableHelp(base, curlError) {
  const isProd = base.includes('workers.dev')

  console.error(`\nCannot reach ${base}`)
  if (curlError) console.error(`  ${curlError}`)

  if (isProd) {
    console.error(`
Production (${base}) failed from this shell — usually TLS reset (curl 35) or PAC proxy.
  • Safari /health works? → Worker is fine; CLI/app use a different network path.
  • Test local dev instead:  pnpm smoke:dev   (needs: pnpm dev:remote on :8787)
  • Test prod from Terminal: pnpm smoke:prod  (same URL as the app Settings)`)
  } else {
    console.error(`
Local dev (${base}) is not responding.
  • Start it:  cd Backend && pnpm dev:remote
  • Plain pnpm dev breaks /api/* (KV needs --remote).`)
  }
}

async function request(label, { base, path, query, token, expectStatus, method = 'GET', bodyKind = 'json', timeoutMs = TIMEOUT_MS }) {
  const url = new URL(path, base.endsWith('/') ? base : `${base}/`)
  if (query) {
    for (const [k, v] of Object.entries(query)) {
      if (v != null && v !== '') url.searchParams.set(k, v)
    }
  }

  const headers = {}
  if (token) headers['X-MovieBox-Token'] = token

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)

  const started = Date.now()
  let status = 0
  let ok = false
  let detail = ''
  let payload = null

  try {
    const res = await fetch(url.toString(), { method, headers, signal: controller.signal })
    status = res.status
    const ct = res.headers.get('content-type') ?? ''

    if (bodyKind === 'json' && ct.includes('application/json')) {
      payload = await res.json()
    } else if (bodyKind === 'binary') {
      const buf = await res.arrayBuffer()
      payload = { bytes: buf.byteLength }
    } else {
      const text = await res.text()
      payload = { text: text.slice(0, 200) }
    }

    const expected = expectStatus ?? [200]
    const allowed = Array.isArray(expected) ? expected : [expected]
    ok = allowed.includes(status)

    if (!ok) {
      const err = payload?.error ?? payload?.message
      detail = err ? String(err) : `HTTP ${status}`
    } else if (bodyKind === 'json' && payload && typeof payload === 'object') {
      detail = summarize(label, payload)
    } else if (bodyKind === 'binary') {
      detail = `${payload.bytes} bytes`
    }
  } catch (e) {
    ok = false
    if (e instanceof Error) {
      const cause = e.cause instanceof Error ? e.cause.message : e.cause ? String(e.cause) : ''
      detail = cause ? `${e.message} (${cause})` : e.message
    } else {
      detail = String(e)
    }
    if (detail.includes('abort')) detail = `timeout after ${timeoutMs}ms`
  } finally {
    clearTimeout(timer)
  }

  const ms = Date.now() - started
  return { label, ok, status, ms, detail, url: url.toString(), payload }
}

function summarize(label, data) {
  if (label === 'health' || label === 'api/status') {
    return data.ok === true ? 'ok: true' : `ok: ${data.ok}`
  }
  if (label.startsWith('api/tmdb')) {
    const n = Array.isArray(data.results) ? data.results.length : 0
    return `${n} results`
  }
  if (label === 'api/title') {
    const title = data.title ?? data.name ?? '?'
    return `"${title}"`
  }
  if (label === 'api/logo') {
    return data.url ? 'logo url present' : 'url: null'
  }
  if (label === 'api/torrent/search') {
    const n = Array.isArray(data.results) ? data.results.length : 0
    return `${n} torrents`
  }
  if (label === 'api/subtitles/search') {
    const n = Array.isArray(data.subtitles) ? data.subtitles.length : 0
    return `${n} subtitles`
  }
  if (label === 'api/trailer/resolve') {
    return data.url ? 'stream url present' : 'no url'
  }
  if (label === 'api/config') {
    return `indexers: ${(data.indexers ?? []).length}`
  }
  return 'OK'
}

async function main() {
  const dev = loadDevVars()
  const base = trimBase(process.env.MOVIEBOX_WORKER_URL ?? DEFAULT_BASE)
  const token = process.env.APP_SECRET ?? dev.APP_SECRET

  if (!token) {
    console.error('Missing APP_SECRET. Set APP_SECRET or add to Backend/.dev.vars')
    process.exit(1)
  }

  console.log(`MovieBox Worker smoke test`)
  console.log(`Base: ${base}`)
  console.log(`Token: ${token.slice(0, 4)}…${token.slice(-4)} (${token.length} chars)`)
  console.log('')
  printProxyHint()

  const endpointPlan = [
    'GET /health (public)',
    'GET /api/config, /api/status (auth)',
    'GET /api/tmdb/* ×6 — catalog, search, genres',
    'GET /api/title/movie/550 — detail bundle',
    'GET /api/logo/movie/550',
    'GET /api/trailer/resolve?key=…',
    'GET /api/torrent/search + /api/torrent/metadata',
    'GET /api/subtitles/search + /api/subtitles/download',
    'GET /api/omdb, /api/fanart/movies/:imdbId',
    'GET /img?u=… (image proxy)',
  ]
  console.log('Endpoints under test:')
  for (const line of endpointPlan) console.log(`  • ${line}`)
  console.log('')

  const probe = await request('connectivity probe', { base, path: '/health', token: null, expectStatus: 200 })
  if (!probe.ok) {
    console.log('Node fetch failed; retrying /health via /usr/bin/curl …')
    const curl = curlRequest(`${base}/health`, null)
    if (curl.status !== 200) {
      const localDevUp = await isLocalDevReachable()
      const curlErr = curl.error ?? `curl HTTP ${curl.status || '—'}`
      printUnreachableHelp(base, curlErr)
      if (base.includes('workers.dev') && localDevUp) {
        console.error(`
Note: ${LOCAL_DEV_URL} is up (wrangler dev is running).
  → You ran prod smoke against workers.dev, not your local server.
  → Run:  pnpm smoke:dev`)
      }
      process.exit(1)
    }
    console.log(`curl /health OK (HTTP ${curl.status})\n`)
  } else {
    console.log(`Connectivity OK (${probe.ms}ms) — running full endpoint suite…\n`)
  }

  const results = []

  // —— Public (app: health check, no auth) ——
  results.push(
    await request('health', { base, path: '/health', token: null, expectStatus: 200 })
  )

  // —— Auth sanity ——
  results.push(
    await request('api/config (no token)', {
      base,
      path: '/api/config',
      token: null,
      expectStatus: 401,
    })
  )
  results.push(
    await request('api/config (bad token)', {
      base,
      path: '/api/config',
      token: 'invalid-token',
      expectStatus: 401,
    })
  )

  // —— App: Settings / torrent sync ——
  results.push(
    await request('api/config', { base, path: '/api/config', token, expectStatus: 200 })
  )
  results.push(
    await request('api/status', { base, path: '/api/status', token, expectStatus: 200 })
  )

  // —— App: Home / Catalog (MetadataClient → /api/tmdb/*) ——
  const tmdbPaths = [
    ['api/tmdb trending', '/api/tmdb/trending/movie/week', { page: '1' }],
    ['api/tmdb popular', '/api/tmdb/movie/popular', { page: '1' }],
    ['api/tmdb top_rated', '/api/tmdb/movie/top_rated', { page: '1' }],
    ['api/tmdb now_playing', '/api/tmdb/movie/now_playing', { page: '1' }],
    ['api/tmdb genre list', '/api/tmdb/genre/movie/list', null],
    ['api/tmdb search', '/api/tmdb/search/movie', { query: 'Fight Club', page: '1' }],
  ]
  for (const [label, path, query] of tmdbPaths) {
    results.push(await request(label, { base, path, query, token, expectStatus: 200 }))
  }

  // —— App: detail bundle ——
  const title = await request('api/title', {
    base,
    path: `/api/title/movie/${SAMPLE_MOVIE_ID}`,
    token,
    expectStatus: 200,
  })
  results.push(title)

  // —— App: AsyncLogoView ——
  results.push(
    await request('api/logo', {
      base,
      path: `/api/logo/movie/${SAMPLE_MOVIE_ID}`,
      token,
      expectStatus: 200,
    })
  )

  // —— App: trailer (needs YouTube key from bundle) ——
  let trailerKey = null
  const videos = title.payload?.videos?.results
  if (Array.isArray(videos)) {
    const yt = videos.find((v) => v?.site === 'YouTube' && v?.type === 'Trailer' && v?.key)
    trailerKey = yt?.key ?? videos.find((v) => v?.key)?.key ?? null
  }
  if (trailerKey) {
    results.push(
      await request('api/trailer/resolve', {
        base,
        path: '/api/trailer/resolve',
        query: { key: trailerKey },
        token,
        expectStatus: [200, 404],
      })
    )
  } else {
    results.push({
      label: 'api/trailer/resolve',
      ok: false,
      status: 0,
      ms: 0,
      detail: 'skipped — no YouTube trailer key in title bundle',
      url: '',
      payload: null,
    })
  }

  // —— App: torrent search (TorrentSection) ——
  const configRes = results.find((r) => r.label === 'api/config')?.payload
  const enabled =
    configRes?.defaultEnabledIndexers?.join(',') ?? 'torrentio,yts,1337x'
  results.push(
    await request('api/torrent/search', {
      base,
      path: '/api/torrent/search',
      query: { q: 'Fight Club', kind: 'movie', year: '1999', enabled },
      token,
      expectStatus: 200,
    })
  )

  // —— App: torrent metadata (404 acceptable — hash rarely on public caches) ——
  const placeholderHash = 'a'.repeat(40)
  results.push(
    await request('api/torrent/metadata', {
      base,
      path: '/api/torrent/metadata',
      query: { hash: placeholderHash },
      token,
      expectStatus: [200, 404],
      bodyKind: 'binary',
      timeoutMs: 15_000,
    })
  )

  // —— App: subtitles ——
  const subSearch = await request('api/subtitles/search', {
    base,
    path: '/api/subtitles/search',
    query: { title: 'Fight Club', year: '1999', type: 'movie', language: 'english' },
    token,
    expectStatus: 200,
    timeoutMs: 60_000,
  })
  results.push(subSearch)

  const firstSubPath = subSearch.payload?.subtitles?.[0]?.path
  if (firstSubPath) {
    results.push(
      await request('api/subtitles/download', {
        base,
        path: '/api/subtitles/download',
        query: { url: firstSubPath },
        token,
        expectStatus: [200, 400, 404, 502],
        bodyKind: 'binary',
        timeoutMs: 60_000,
      })
    )
  } else {
    results.push({
      label: 'api/subtitles/download',
      ok: true,
      status: 0,
      ms: 0,
      detail: 'skipped — no subtitle path from search',
      url: '',
      payload: null,
    })
  }

  // —— Legacy / optional proxies ——
  results.push(
    await request('api/omdb', {
      base,
      path: '/api/omdb',
      query: { i: SAMPLE_IMDB },
      token,
      expectStatus: [200, 503],
      timeoutMs: 45_000,
    })
  )
  results.push(
    await request('api/fanart/movies', {
      base,
      path: `/api/fanart/movies/${SAMPLE_IMDB}`,
      token,
      expectStatus: [200, 502],
      timeoutMs: 45_000,
    })
  )

  // —— Image proxy (no auth; rate-limited) ——
  results.push(
    await request('img proxy', {
      base,
      path: '/img',
      query: {
        u: 'https://image.tmdb.org/t/p/w342/pB8BM7pdSp6B6Ih7QZ4DrFu3WJ9.jpg',
      },
      token: null,
      expectStatus: 200,
      bodyKind: 'binary',
      timeoutMs: 45_000,
    })
  )

  // —— Report ——
  const pad = (s, n) => String(s).padEnd(n)
  const w = Math.max(28, ...results.map((r) => r.label.length))
  let failed = 0
  for (const r of results) {
    const mark = r.ok ? 'PASS' : 'FAIL'
    if (!r.ok) failed++
    const status = r.status ? String(r.status) : '—'
    console.log(`${pad(r.label, w)}  ${mark}  ${status.padStart(3)}  ${String(r.ms).padStart(5)}ms  ${r.detail}`)
    if (!r.ok && r.url) console.log(`  → ${r.url}`)
  }

  console.log('')
  const passed = results.length - failed
  console.log(`${passed}/${results.length} checks passed`)
  if (failed > 0) {
    const healthOk = results.find((r) => r.label === 'health')?.ok
    const api500 = results.some((r) => r.label.startsWith('api/') && r.status === 500)
    console.log('\nTroubleshooting:')
    if (base.startsWith('http://127.0.0.1') && healthOk && api500) {
      console.log('  • /health OK but /api/* 500 → KV not wired. Use: pnpm dev:remote  (not plain pnpm dev)')
    }
    if (base.includes('workers.dev')) {
      console.log('  • Prod TLS reset (curl 35) → PAC proxy; Safari may still work. Try: pnpm smoke:prod in Terminal.app')
      console.log('  • Or test local: pnpm dev:remote && pnpm smoke:dev')
    }
    console.log('  • /health OK, /api/* 401 → APP_SECRET in .dev.vars ≠ Worker secret.')
    process.exit(1)
  }
}

main()
