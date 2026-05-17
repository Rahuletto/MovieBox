import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { timing } from 'hono/timing'
import { logger } from 'hono/logger'
import { secureHeaders } from 'hono/secure-headers'

type Bindings = {
  TMDB_TOKEN: string
  OMDB_API_KEY?: string
  APP_SECRET: string
  APP_ENV: string
  CORS_ORIGIN: string
  RATE_LIMIT_WINDOW_MS: string
  RATE_LIMIT_MAX_REQUESTS: string
  MOVIEBOX_CACHE: KVNamespace
}

type Variables = {
  requestId: string
  startTime: number
}

const app = new Hono<{ Bindings: Bindings; Variables: Variables }>()

// Security headers
app.use('*', secureHeaders())

// Request logging with timing
app.use('*', timing())
app.use('*', async (c, next) => {
  c.set('requestId', crypto.randomUUID())
  c.set('startTime', Date.now())
  await next()
  const duration = Date.now() - c.get('startTime')
  const status = c.res.status
  const method = c.req.method
  const path = c.req.path
  const requestId = c.get('requestId')

  if (c.env.APP_ENV === 'development') {
    console.log(`[${requestId}] ${method} ${path} -> ${status} (${duration}ms)`)
  }
})

// Configurable CORS
app.use('/api/*', async (c, next) => {
  const origin = c.env.CORS_ORIGIN || '*'
  const corsHandler = cors({
    origin: origin === '*' ? '*' : origin.split(',').map(o => o.trim()),
    allowMethods: ['GET', 'POST', 'OPTIONS'],
    allowHeaders: ['Content-Type', 'X-MovieBox-Token'],
    maxAge: 86400,
  })
  return corsHandler(c, next)
})

// Rate limiting middleware
app.use('/api/*', async (c, next) => {
  const windowMs = parseInt(c.env.RATE_LIMIT_WINDOW_MS || '60000')
  const maxRequests = parseInt(c.env.RATE_LIMIT_MAX_REQUESTS || '100')
  const clientIp = c.req.header('CF-Connecting-IP') || c.req.header('X-Forwarded-For') || 'unknown'
  const cacheKey = `rate_limit:${clientIp}:${Math.floor(Date.now() / windowMs)}`

  const current = await c.env.MOVIEBOX_CACHE.get(cacheKey)
  const count = current ? parseInt(current) : 0

  if (count >= maxRequests) {
    return c.json(
      {
        error: 'rate_limit_exceeded',
        message: `Too many requests. Try again in ${Math.ceil(windowMs / 1000)}s.`,
        retryAfter: Math.ceil(windowMs / 1000),
      },
      429
    )
  }

  await c.env.MOVIEBOX_CACHE.put(cacheKey, String(count + 1), { expirationTtl: Math.ceil(windowMs / 1000) })
  c.res.headers.set('X-RateLimit-Limit', String(maxRequests))
  c.res.headers.set('X-RateLimit-Remaining', String(maxRequests - count - 1))

  await next()
})

// Health check (no auth required)
app.get('/health', (c) => {
  return c.json({
    ok: true,
    service: 'moviebox-backend',
    timestamp: new Date().toISOString(),
    env: c.env.APP_ENV || 'unknown',
  })
})

// Auth middleware for API routes
app.use('/api/*', async (c, next) => {
  const token = c.req.header('X-MovieBox-Token')
  if (!c.env.APP_SECRET || token !== c.env.APP_SECRET) {
    return c.json(
      {
        error: 'unauthorized',
        message: 'Valid X-MovieBox-Token header is required.',
      },
      401
    )
  }
  await next()
})

// TMDB proxy
app.all('/api/tmdb/*', async (c) => {
  try {
    const upstreamPath = c.req.path.replace('/api/tmdb', '')
    const upstreamURL = new URL(c.req.url)
    upstreamURL.protocol = 'https:'
    upstreamURL.hostname = 'api.themoviedb.org'
    upstreamURL.port = ''
    upstreamURL.pathname = `/3${upstreamPath}`

    const headers: Record<string, string> = {
      Authorization: `Bearer ${c.env.TMDB_TOKEN}`,
    }

    const cacheKey = `tmdb:${upstreamPath}:${upstreamURL.search}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)

    if (cached) {
      const parsed = JSON.parse(cached)
      return c.json(parsed.data, {
        headers: {
          'X-Cache': 'HIT',
          'Cache-Control': parsed.cacheControl || 'public, max-age=1800',
        },
      })
    }

    const isLocal = c.req.url.includes('127.0.0.1') || c.req.url.includes('localhost')
    const fetchOptions: any = { headers }
    if (!isLocal) {
      fetchOptions.cf = {
        cacheEverything: true,
        cacheTtl: cacheTTLForTMDBPath(upstreamPath),
      }
    }
    const response = await fetch(upstreamURL.toString(), fetchOptions)

    if (!response.ok) {
      const errorBody = await response.text()
      return c.json(
        {
          error: 'upstream_error',
          message: `TMDB returned ${response.status}`,
          status: response.status,
          body: errorBody,
        },
        response.status
      )
    }

    const data = await response.json()
    const ttl = cacheTTLForTMDBPath(upstreamPath)
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify({ data, cacheControl: `public, max-age=${ttl}` }), {
      expirationTtl: ttl,
    })

    return c.json(data, {
      headers: {
        'X-Cache': 'MISS',
        'Cache-Control': `public, max-age=${ttl}`,
      },
    })
  } catch (error) {
    return c.json(
      {
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : 'Unknown proxy error',
      },
      502
    )
  }
})

// OMDb proxy
app.get('/api/omdb', async (c) => {
  try {
    const imdbId = c.req.query('i')
    if (!imdbId) {
      return c.json({ error: 'bad_request', message: 'Missing imdb id. Use ?i=tt0000000' }, 400)
    }
    if (!c.env.OMDB_API_KEY) {
      return c.json({ error: 'service_unavailable', message: 'OMDb is not configured.' }, 503)
    }

    const url = new URL('https://www.omdbapi.com/')
    url.searchParams.set('i', imdbId)
    url.searchParams.set('apikey', c.env.OMDB_API_KEY)

    const cacheKey = `omdb:${imdbId}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)

    if (cached) {
      return c.json(JSON.parse(cached), { headers: { 'X-Cache': 'HIT' } })
    }

    const isLocal = c.req.url.includes('127.0.0.1') || c.req.url.includes('localhost')
    const fetchOptions: any = {}
    if (!isLocal) {
      fetchOptions.cf = { cacheEverything: true, cacheTtl: 60 * 60 * 24 }
    }
    const response = await fetch(url.toString(), fetchOptions)

    const data = await response.json()
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(data), { expirationTtl: 60 * 60 * 24 })

    return c.json(data, { headers: { 'X-Cache': 'MISS' } })
  } catch (error) {
    return c.json(
      {
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : 'Unknown proxy error',
      },
      502
    )
  }
})

// Subf2m subtitle search and download
app.get('/api/subtitles/search', async (c) => {
  try {
    const title = c.req.query('title')
    const year = c.req.query('year')
    const language = c.req.query('language') || 'english'
    const type = c.req.query('type') || 'movie'
    const imdbId = c.req.query('imdb_id')

    if (!title && !imdbId) {
      return c.json({ error: 'bad_request', message: 'Missing title or imdb_id parameter.' }, 400)
    }

    const cacheKey = `subf2m:search:${title}:${year}:${language}:${type}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey)
    if (cached) {
      return c.json(JSON.parse(cached), { headers: { 'X-Cache': 'HIT' } })
    }

    const searchQuery = title || ''
    const searchUrl = `https://subf2m.co/subtitles/searchbytitle?query=${encodeURIComponent(searchQuery)}&l=`
    const searchHtml = await fetchWithTimeout(searchUrl)

    if (!searchHtml) {
      return c.json({ subtitles: [] })
    }

    const results = parseSubf2mSearchResults(searchHtml, year)
    if (results.length === 0) {
      return c.json({ subtitles: [] })
    }

    const subtitles: SubtitleResult[] = []
    for (const result of results.slice(0, 3)) {
      const detailUrl = `https://subf2m.co${result.path}/${normalizeLanguageCode(language)}`
      const detailHtml = await fetchWithTimeout(detailUrl)
      if (detailHtml) {
        const items = parseSubf2mDetailPage(detailHtml, result.path, language)
        subtitles.push(...items)
      }
    }

    const response = { subtitles }
    await c.env.MOVIEBOX_CACHE.put(cacheKey, JSON.stringify(response), { expirationTtl: 60 * 60 * 6 })
    return c.json(response, { headers: { 'X-Cache': 'MISS' } })
  } catch (error) {
    return c.json(
      {
        error: 'subtitle_search_failed',
        message: error instanceof Error ? error.message : 'Unknown error',
      },
      502
    )
  }
})

app.get('/api/subtitles/download', async (c) => {
  try {
    const subtitleUrl = c.req.query('url')
    if (!subtitleUrl) {
      return c.json({ error: 'bad_request', message: 'Missing url parameter.' }, 400)
    }

    const cacheKey = `subf2m:dl:${btoa(subtitleUrl)}`
    const cached = await c.env.MOVIEBOX_CACHE.get(cacheKey, 'arrayBuffer')
    if (cached) {
      return c.body(cached, {
        headers: {
          'Content-Type': 'application/x-subrip',
          'X-Cache': 'HIT',
        },
      })
    }

    const fullUrl = subtitleUrl.startsWith('http') ? subtitleUrl : `https://subf2m.co${subtitleUrl}`
    const html = await fetchWithTimeout(fullUrl)
    if (!html) {
      return c.json({ error: 'not_found', message: 'Could not fetch subtitle page.' }, 404)
    }

    const downloadLink = extractSubf2mDownloadLink(html)
    if (!downloadLink) {
      return c.json({ error: 'not_found', message: 'No download link found.' }, 404)
    }

    const dlUrl = downloadLink.startsWith('http') ? downloadLink : `https://subf2m.co${downloadLink}`
    const zipResponse = await fetchWithTimeout(dlUrl, { returnType: 'arrayBuffer' })
    if (!zipResponse) {
      return c.json({ error: 'download_failed', message: 'Failed to download subtitle ZIP.' }, 502)
    }

    const srtContent = await extractSrtFromZip(zipResponse as ArrayBuffer)
    if (!srtContent) {
      return c.json({ error: 'extract_failed', message: 'No SRT file found in ZIP.' }, 502)
    }

    await c.env.MOVIEBOX_CACHE.put(cacheKey, srtContent, { expirationTtl: 60 * 60 * 24 })
    return c.body(srtContent, {
      headers: {
        'Content-Type': 'application/x-subrip',
        'X-Cache': 'MISS',
      },
    })
  } catch (error) {
    return c.json(
      {
        error: 'subtitle_download_failed',
        message: error instanceof Error ? error.message : 'Unknown error',
      },
      502
    )
  }
})

interface Subf2mSearchResult {
  title: string
  year: string
  path: string
}

interface SubtitleResult {
  id: string
  name: string
  author: string
  language: string
  downloadUrl: string
}

function normalizeLanguageCode(lang: string): string {
  const map: Record<string, string> = {
    en: 'english',
    english: 'english',
    ar: 'arabic',
    arabic: 'arabic',
    es: 'spanish',
    spanish: 'spanish',
    fr: 'french',
    french: 'french',
    de: 'german',
    german: 'german',
    pt: 'portuguese',
    portuguese: 'portuguese',
    ru: 'russian',
    russian: 'russian',
    tr: 'turkish',
    turkish: 'turkish',
    it: 'italian',
    italian: 'italian',
    nl: 'dutch',
    dutch: 'dutch',
    ko: 'korean',
    korean: 'korean',
    ja: 'japanese',
    japanese: 'japanese',
    zh: 'chinese',
    chinese: 'chinese',
    fa: 'farsi',
    farsi: 'farsi',
    ur: 'urdu',
    urdu: 'urdu',
    hi: 'hindi',
    hindi: 'hindi',
    bn: 'bengali',
    bengali: 'bengali',
    id: 'indonesian',
    indonesian: 'indonesian',
    vi: 'vietnamese',
    vietnamese: 'vietnamese',
    th: 'thai',
    thai: 'thai',
    sv: 'swedish',
    swedish: 'swedish',
    da: 'danish',
    danish: 'danish',
    fi: 'finnish',
    finnish: 'finnish',
    no: 'norwegian',
    norwegian: 'norwegian',
    pl: 'polish',
    polish: 'polish',
    he: 'hebrew',
    hebrew: 'hebrew',
    el: 'greek',
    greek: 'greek',
    hu: 'hungarian',
    hungarian: 'hungarian',
    ro: 'romanian',
    romanian: 'romanian',
    bg: 'bulgarian',
    bulgarian: 'bulgarian',
    hr: 'croatian',
    croatian: 'croatian',
    sr: 'serbian',
    serbian: 'serbian',
    uk: 'ukrainian',
    ukrainian: 'ukrainian',
    ms: 'malay',
    malay: 'malay',
    my: 'burmese',
    burmese: 'burmese',
    ku: 'kurdish',
    kurdish: 'kurdish',
    mk: 'macedonian',
    macedonian: 'macedonian',
    ml: 'malayalam',
    malayalam: 'malayalam',
    sl: 'slovenian',
    slovenian: 'slovenian',
    si: 'sinhala',
    sinhala: 'sinhala',
  }
  return map[lang.toLowerCase()] || lang.toLowerCase()
}

function parseSubf2mSearchResults(html: string, targetYear?: string | null): Subf2mSearchResult[] {
  const results: Subf2mSearchResult[] = []

  const searchResultStart = html.indexOf('<div class="search-result">')
  if (searchResultStart === -1) return results

  const afterStart = html.substring(searchResultStart)

  const ulMatch = afterStart.match(/<h2 class="(exact|close|popular)">[\s\S]*?<ul>([\s\S]*?)<\/ul>/i)
  if (!ulMatch) return results

  const listHtml = ulMatch[2]
  const itemRegex = /<li>[\s\S]*?<a href="([^"]+)">([^<]+)<\/a>[\s\S]*?<\/li>/g
  let match

  while ((match = itemRegex.exec(listHtml)) !== null) {
    const path = match[1]
    const fullTitle = match[2].trim()

    const yearMatch = fullTitle.match(/\((\d{4})\)/)
    const year = yearMatch ? yearMatch[1] : null

    const title = fullTitle.replace(/\s*\(.*$/, '').trim()

    if (targetYear && year && year !== targetYear) continue

    results.push({ title, year: year || '', path })
  }

  return results
}

function parseSubf2mDetailPage(html: string, basePath: string, language: string): SubtitleResult[] {
  const subtitles: SubtitleResult[] = []
  const lang = normalizeLanguageCode(language)

  const itemRegex = /<li class='item\s*'>([\s\S]*?)<\/li>\s*(?=<li class='item|$)/g
  let itemMatch

  while ((itemMatch = itemRegex.exec(html)) !== null) {
    const itemHtml = itemMatch[1]

    const downloadMatch = itemHtml.match(/<a\s+class='download\s+icon-download'\s+href='([^']+)'/i)
    if (!downloadMatch) continue

    const downloadUrl = downloadMatch[1]

    const authorMatch = itemHtml.match(/<b>By\s*<a[^>]*>([^<]+)<\/a>/i)
    const author = authorMatch ? authorMatch[1].trim() : 'Unknown'

    const releaseMatch = itemHtml.match(/<ul class='scrolllist'>[\s\S]*?<li>([^<]+)<\/li>/i)
    const release = releaseMatch ? releaseMatch[1].trim() : ''

    const name = release || author

    subtitles.push({
      id: btoa(`${downloadUrl}___${lang}`),
      name,
      author,
      language: lang,
      downloadUrl,
    })
  }

  return subtitles
}

function extractSubf2mDownloadLink(html: string): string | null {
  const downloadDivMatch = html.match(/<div class="download">([\s\S]*?)<\/div>/i)
  if (!downloadDivMatch) return null

  const downloadDiv = downloadDivMatch[1]
  const linkMatch = downloadDiv.match(/<a[^>]*href="([^"]+)"/i)
  return linkMatch ? linkMatch[1] : null
}

async function extractSrtFromZip(zipBuffer: ArrayBuffer): Promise<string | null> {
  try {
    const { ZipReader, BlobReader, TextWriter, Uint8ArrayWriter } = await import('@zip.js/zip.js')

    const blob = new Blob([zipBuffer])
    const zipReader = new ZipReader(new BlobReader(blob))
    const entries = await zipReader.getEntries()

    const srtEntry = entries.find(e => e.filename.toLowerCase().endsWith('.srt')) ||
                     entries.find(e => e.filename.toLowerCase().endsWith('.sub')) ||
                     entries.find(e => e.filename.toLowerCase().includes('utf')) ||
                     entries[0]

    if (!srtEntry || !srtEntry.getData) return null

    const writer = srtEntry.filename.toLowerCase().endsWith('.sub')
      ? new Uint8ArrayWriter()
      : new TextWriter()

    const content = await srtEntry.getData(writer)
    await zipReader.close()

    if (typeof content === 'string') return content

    const decoder = new TextDecoder('utf-8')
    return decoder.decode(content as Uint8Array)
  } catch {
    const decoder = new TextDecoder('utf-8')
    return decoder.decode(new Uint8Array(zipBuffer))
  }
}

async function fetchWithTimeout(
  url: string,
  options: { timeout?: number; returnType?: 'text' | 'arrayBuffer' } = {}
): Promise<string | ArrayBuffer | null> {
  const { timeout = 10000, returnType = 'text' } = options

  const controller = new AbortController()
  const id = setTimeout(() => controller.abort(), timeout)

  try {
    const response = await fetch(url, { signal: controller.signal })
    clearTimeout(id)

    if (!response.ok) return null

    return returnType === 'arrayBuffer' ? await response.arrayBuffer() : await response.text()
  } catch {
    clearTimeout(id)
    return null
  }
}

// 404 handler
app.notFound((c) => {
  return c.json({ error: 'not_found', message: `Route ${c.req.method} ${c.req.path} not found.` }, 404)
})

// Error handler
app.onError((error, c) => {
  const requestId = c.get('requestId') || 'unknown'
  console.error(`[${requestId}] Unhandled error:`, error)

  return c.json(
    {
      error: 'internal_error',
      message: c.env.APP_ENV === 'development' ? error.message : 'An unexpected error occurred.',
      requestId,
    },
    500
  )
})

function cacheTTLForTMDBPath(path: string): number {
  if (path.startsWith('/genre/')) return 60 * 60 * 24
  if (path.includes('/credits') || path.includes('/images') || path.includes('/videos')) return 60 * 60 * 6
  if (path.startsWith('/movie/top_rated')) return 60 * 60
  if (path.startsWith('/movie/now_playing')) return 60 * 15
  if (path.startsWith('/search/')) return 60 * 30
  return 60 * 30
}

export default app
