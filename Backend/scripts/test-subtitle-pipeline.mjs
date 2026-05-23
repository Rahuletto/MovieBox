#!/usr/bin/env node
/** Quick local test of subtitle scrape pipeline (no worker). */

const SUBF2M_FETCH_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  Accept: 'text/html,application/xhtml+xml',
}

async function fetchText(url, timeoutMs = 30000) {
  const controller = new AbortController()
  const id = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const response = await fetch(url, { signal: controller.signal, headers: SUBF2M_FETCH_HEADERS })
    clearTimeout(id)
    if (!response.ok) return null
    return await response.text()
  } catch (e) {
    clearTimeout(id)
    console.error('fetch failed', url, e.message)
    return null
  }
}

function normalizeLanguageCode(lang) {
  const normalized = lang.trim().toLowerCase()
  if (normalized === 'all' || normalized === '*') return 'all'
  const map = { en: 'english', english: 'english', all: 'all' }
  return map[normalized] || normalized
}

function parseSubf2mSearchResults(html, targetYear) {
  const results = []
  const seenPaths = new Set()
  const searchResultStart = html.indexOf('<div class="search-result">')
  if (searchResultStart === -1) return results
  const afterStart = html.substring(searchResultStart)
  const sectionRegex =
    /<h2[^>]*class="(?:exact|close|popular)"[^>]*>[\s\S]*?<ul>([\s\S]*?)<\/ul>/gi
  let sectionMatch
  const addResult = (path, fullTitle) => {
    if (!path.startsWith('/subtitles/') || seenPaths.has(path)) return
    const yearMatch = fullTitle.match(/\((\d{4})\)/)
    const year = yearMatch ? yearMatch[1] : null
    const title = fullTitle.replace(/\s*\(\d{4}\).*$/, '').replace(/\s+/g, ' ').trim()
    if (targetYear && year && year !== targetYear) return
    seenPaths.add(path)
    results.push({ title, year: year || '', path })
  }
  while ((sectionMatch = sectionRegex.exec(afterStart)) !== null) {
    const listHtml = sectionMatch[1]
    const itemRegex =
      /<li>[\s\S]*?<a\s+href="(\/subtitles\/[^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/li>/gi
    let match
    while ((match = itemRegex.exec(listHtml)) !== null) {
      addResult(match[1], match[2].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim())
    }
  }
  if (results.length === 0) {
    const fallbackRegex = /<a\s+href="(\/subtitles\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/gi
    let match
    while ((match = fallbackRegex.exec(afterStart)) !== null) {
      addResult(match[1], match[2].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim())
    }
  }
  return results
}

function parseSubf2mDetailPage(html, language) {
  const subtitles = []
  const fallbackLang = normalizeLanguageCode(language)
  const itemRegex = /<li class='item\s*'>([\s\S]*?)<\/li>\s*(?=<li class='item|$)/g
  let itemMatch
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
    subtitles.push({ name: release || author, author, language: itemLang, downloadUrl })
  }
  return subtitles
}

async function search({ title, year, imdbId, language = 'all' }) {
  const langParam = normalizeLanguageCode(language)
  const searchQueries = []
  if (imdbId) searchQueries.push(`tt${imdbId.replace(/^tt/i, '')}`)
  if (title?.trim()) searchQueries.push(title.trim())

  let results = []
  for (const searchQuery of searchQueries) {
    const searchUrl = `https://subf2m.co/subtitles/searchbytitle?query=${encodeURIComponent(searchQuery)}&l=`
    const searchHtml = await fetchText(searchUrl)
    if (!searchHtml) continue
    results = parseSubf2mSearchResults(searchHtml, year)
    if (results.length === 0 && year) {
      results = parseSubf2mSearchResults(searchHtml, null)
    }
    if (results.length > 0) break
  }

  const subtitles = []
  const seen = new Set()
  for (const result of results.slice(0, 5)) {
    const detailPath = langParam === 'all' ? result.path : `${result.path}/${langParam}`
    const detailUrl = `https://subf2m.co${detailPath}`
    const detailHtml = await fetchText(detailUrl)
    if (!detailHtml) {
      console.warn('detail fetch failed', detailUrl)
      continue
    }
    const items = parseSubf2mDetailPage(detailHtml, language)
    for (const item of items) {
      if (seen.has(item.downloadUrl)) continue
      seen.add(item.downloadUrl)
      subtitles.push(item)
    }
  }
  return { results: results.length, subtitles: subtitles.length }
}

const cases = [
  { title: 'Interstellar', year: '2014', imdbId: '0816692' },
  { title: 'Fight Club', year: '1999', imdbId: '0137523' },
  { title: 'Interstellar', year: '2015', imdbId: '0816692' }, // wrong year
]

for (const c of cases) {
  const r = await search(c)
  console.log(c.title, 'year=', c.year, '→', r)
}
