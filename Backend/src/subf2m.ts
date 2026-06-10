import { assertSafeSubtitleURL, buildSubf2mURL } from './subtitle-guard'

interface Subf2mSearchResult {
  title: string
  year: string
  path: string
}

export interface SubtitleResult {
  id: string
  name: string
  author: string
  language: string
  downloadUrl: string
}

const SUBF2M_FETCH_HEADERS: Record<string, string> = {
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  Accept: 'text/html,application/xhtml+xml',
  'Accept-Language': 'en-US,en;q=0.9',
}

import { normalizeLanguageCode } from './subtitles/languages'

function parseSubf2mSearchResults(html: string, targetYear?: string | null): Subf2mSearchResult[] {
  const results: Subf2mSearchResult[] = []
  const seenPaths = new Set<string>()
  const searchResultStart = html.indexOf('<div class="search-result">')
  if (searchResultStart === -1) return results

  const afterStart = html.substring(searchResultStart)
  const sectionRegex = /<h2[^>]*>(?:Exact|Close|Popular)[^<]*<\/h2>[\s\S]*?<ul>([\s\S]*?)<\/ul>/gi
  let sectionMatch: RegExpExecArray | null

  const addResult = (path: string, fullTitle: string) => {
    if (!path.startsWith('/subtitles/') || seenPaths.has(path)) return
    const yearMatch = fullTitle.match(/\((\d{4})\)/)
    const year = yearMatch ? yearMatch[1] : null
    const title = fullTitle
      .replace(/\s*\(\d{4}\).*$/, '')
      .replace(/\s+/g, ' ')
      .trim()
    if (targetYear && year && year !== targetYear) return
    seenPaths.add(path)
    results.push({ title, year: year || '', path })
  }

  while ((sectionMatch = sectionRegex.exec(afterStart)) !== null) {
    const listHtml = sectionMatch[1]
    const itemRegex =
      /<li>[\s\S]*?<a\s+href="(\/subtitles\/[^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/li>/gi
    let match: RegExpExecArray | null
    while ((match = itemRegex.exec(listHtml)) !== null) {
      const path = match[1]
      const fullTitle = match[2]
        .replace(/<[^>]+>/g, ' ')
        .replace(/\s+/g, ' ')
        .trim()
      addResult(path, fullTitle)
    }
  }

  if (results.length === 0) {
    const fallbackRegex = /<a\s+href="(\/subtitles\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/gi
    let match: RegExpExecArray | null
    while ((match = fallbackRegex.exec(afterStart)) !== null) {
      const path = match[1]
      const fullTitle = match[2]
        .replace(/<[^>]+>/g, ' ')
        .replace(/\s+/g, ' ')
        .trim()
      addResult(path, fullTitle)
    }
  }

  return results
}

function parseSubf2mDetailPage(html: string, language: string): SubtitleResult[] {
  const subtitles: SubtitleResult[] = []
  const fallbackLang = normalizeLanguageCode(language)
  const itemRegex = /<li class='item\s*'>([\s\S]*?)<\/li>\s*(?=<li class='item|$)/g
  let itemMatch: RegExpExecArray | null

  while ((itemMatch = itemRegex.exec(html)) !== null) {
    const itemHtml = itemMatch[1]
    const downloadMatch = itemHtml.match(
      /<a\s+class=['"]download\s+icon-download['"]\s+href=['"]([^'"]+)['"]/i
    )
    if (!downloadMatch) continue
    const downloadUrl = downloadMatch[1]
    const authorMatch = itemHtml.match(/<b>\s*By\s*<a[^>]*>([^<]+)<\/a>/i)
    const author = authorMatch ? authorMatch[1].replace(/\s+/g, ' ').trim() : 'Unknown'
    const releaseMatch = itemHtml.match(/<ul class='scrolllist'>[\s\S]*?<li>([^<]+)<\/li>/i)
    const release = releaseMatch ? releaseMatch[1].replace(/\s+/g, ' ').trim() : ''
    const langMatch = itemHtml.match(/<span class='language[^']*'>([^<]+)<\/span>/i)
    const itemLang = langMatch
      ? langMatch[1].replace(/\s+/g, ' ').trim().toLowerCase()
      : fallbackLang === 'all'
        ? 'unknown'
        : fallbackLang

    subtitles.push({
      id: btoa(`${downloadUrl}___${itemLang}`),
      name: release || author,
      author,
      language: itemLang,
      downloadUrl,
    })
  }

  return subtitles
}

async function fetchWithTimeout(
  url: string,
  options: { timeout?: number; headers?: Record<string, string> } = {}
): Promise<string | null> {
  const { timeout = 10000, headers } = options
  const controller = new AbortController()
  const id = setTimeout(() => controller.abort(), timeout)
  try {
    const response = await fetch(url, { signal: controller.signal, headers })
    if (!response.ok) return null
    return await response.text()
  } catch {
    return null
  } finally {
    clearTimeout(id)
  }
}

export async function searchSubf2mSubtitles(options: {
  title?: string | null
  year?: number | null
  language?: string
  imdbId?: string | null
}): Promise<SubtitleResult[]> {
  const langParam = normalizeLanguageCode(options.language ?? 'all')
  const searchQueries: string[] = []
  if (options.imdbId?.trim()) searchQueries.push(`tt${options.imdbId.replace(/^tt/i, '').trim()}`)
  if (options.title?.trim()) searchQueries.push(options.title.trim())
  const yearFilter = options.year ? String(options.year) : null
  let results: Subf2mSearchResult[] = []

  for (const searchQuery of searchQueries) {
    const searchUrl = buildSubf2mURL(
      `/subtitles/searchbytitle?query=${encodeURIComponent(searchQuery)}&l=`
    ).toString()
    const searchHtml = await fetchWithTimeout(searchUrl, {
      headers: SUBF2M_FETCH_HEADERS,
      timeout: 20000,
    })
    if (!searchHtml) continue
    results = parseSubf2mSearchResults(searchHtml, yearFilter)
    if (results.length === 0 && yearFilter) {
      results = parseSubf2mSearchResults(searchHtml, null)
    }
    if (results.length > 0) break
  }

  if (results.length === 0) return []
  const subtitles: SubtitleResult[] = []
  const seenDownloadUrls = new Set<string>()
  for (const result of results.slice(0, 5)) {
    const detailPath = langParam === 'all' ? result.path : `${result.path}/${langParam}`
    const detailUrl = buildSubf2mURL(detailPath).toString()
    const detailHtml = await fetchWithTimeout(detailUrl, {
      headers: SUBF2M_FETCH_HEADERS,
      timeout: 30000,
    })
    if (!detailHtml) continue
    const items = parseSubf2mDetailPage(detailHtml, options.language ?? 'all')
    for (const item of items) {
      if (seenDownloadUrls.has(item.downloadUrl)) continue
      seenDownloadUrls.add(item.downloadUrl)
      try {
        const rawUrl = item.downloadUrl
        const normalizedUrl = rawUrl.startsWith('http') ? rawUrl : buildSubf2mURL(rawUrl).toString()
        item.downloadUrl = assertSafeSubtitleURL(normalizedUrl).toString()
        subtitles.push(item)
      } catch {
        continue
      }
    }
  }
  return subtitles
}
