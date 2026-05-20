#!/usr/bin/env node
/**
 * Spot-check Rotten Tomatoes HTML parsing (Tomatometer vs audience sanity).
 *
 * Usage: node scripts/verify-rotten-tomatoes.mjs
 * Network required — scores drift over time; this checks structure + consistency.
 */

const UA = {
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  Accept: 'text/html,application/xhtml+xml',
}

/** Mirror of Backend/src/rotten-tomatoes.ts parseCriticsScoreFromHtml */
function parseCriticsScoreFromHtml(html) {
  const matches = [...html.matchAll(/"criticsScore":(\{[^}]+\})/g)]
  if (matches.length === 0) return null
  let best = null
  let bestRc = -1
  for (const m of matches) {
    let p
    try {
      p = JSON.parse(m[1])
    } catch {
      continue
    }
    const pct = p.score ? parseInt(p.score, 10) : p.scorePercent?.match(/(\d+)/)?.[1]
    if (pct == null || !Number.isFinite(Number(pct))) continue
    const rc = p.reviewCount ?? p.ratingCount ?? 0
    if (rc > bestRc) {
      bestRc = rc
      best = {
        percentage: Number(pct),
        totalReviews: p.reviewCount ?? p.ratingCount ?? null,
        freshCount: p.likedCount ?? null,
        rottenCount: p.notLikedCount ?? null,
        averageScore: p.averageRating ? parseFloat(p.averageRating) : null,
      }
    }
  }
  return best
}

function firstAudienceScore(html) {
  const m = html.match(/"audienceScore":\{[^}]*"score":"([^"]+)"/)
  return m ? parseInt(m[1], 10) : null
}

function ogTitle(html) {
  const m = html.match(/property="og:title" content="([^"]+)"/)
  return m?.[1]?.replace(/\s*\|\s*Rotten Tomatoes\s*$/i, '') ?? null
}

async function fetchHtml(path) {
  const url = `https://www.rottentomatoes.com${path}`
  const r = await fetch(url, { headers: UA, redirect: 'follow' })
  const html = await r.text()
  return { ok: r.ok, status: r.status, html, url }
}

async function main() {
  console.log('Rotten Tomatoes parser verification\n')

  const cases = [
    { path: '/m/michael', note: 'Michael (2025) — Tomatometer should not equal audience Popcornmeter' },
    { path: '/m/tuner', note: 'Tuner — different title slug sanity' },
    { path: '/m/fight_club', note: 'Fight Club — classic' },
    { path: '/m/project_hail_mary', note: 'Project Hail Mary' },
    { path: '/tv/breaking_bad', note: 'TV show' },
  ]

  let failures = 0
  for (const { path, note } of cases) {
    const { ok, status, html } = await fetchHtml(path)
    const title = ogTitle(html)
    const critics = parseCriticsScoreFromHtml(html)
    const audience = firstAudienceScore(html)
    const blocks = [...html.matchAll(/"criticsScore":(\{[^}]+\})/g)].length

    console.log(`${path}  (${note})`)
    console.log(`  HTTP ${status}  og:title: ${title ?? '(none)'}`)
    console.log(`  criticsScore blocks: ${blocks}  parsed: ${JSON.stringify(critics)}`)
    console.log(`  audienceScore (first): ${audience ?? '—'}`)

    if (!ok || !critics) {
      console.log('  ❌ missing page or Tomatometer\n')
      failures++
      continue
    }

    // Tomatometer and audience are often different; equality on Michael was the bug symptom.
    if (path === '/m/michael' && audience != null && critics.percentage === audience) {
      console.log('  ❌ Tomatometer equals audience — likely parsing wrong block\n')
      failures++
      continue
    }

    if (critics.totalReviews != null && critics.freshCount != null && critics.rottenCount != null) {
      const sum = critics.freshCount + critics.rottenCount
      if (sum !== critics.totalReviews) {
        console.log(
          `  ⚠ fresh+rotten (${sum}) != totalReviews (${critics.totalReviews}) — RT payload quirk?`
        )
      }
    }

    console.log('  ✓\n')
  }

  // Resolver: polluted search must not pick /m/tuner for Michael
  const { html: searchHtml } = await fetchHtml(`/search?search=${encodeURIComponent('Michael 2026')}`)
  const hasMichaelLink = /href="https:\/\/www\.rottentomatoes\.com\/m\/michael"/.test(searchHtml)
  const baseSlug = 'michael'
  const prefix = '/m/'
  const slugs = new Set()
  for (const m of searchHtml.matchAll(/\/m\/([a-z0-9_]+)/gi)) {
    slugs.add(`${prefix}${m[1]}`)
  }
  const relevant = [...slugs].filter((p) => {
    const s = p.slice(prefix.length)
    return s === baseSlug || s.startsWith(`${baseSlug}_`)
  })
  console.log('Search "Michael 2026"')
  console.log(`  explicit /m/michael link in HTML: ${hasMichaelLink}`)
  console.log(`  title-relevant slugs found: ${relevant.length ? relevant.join(', ') : '(none)'}`)
  console.log(
    relevant.length || hasMichaelLink
      ? '  ✓ direct /m/michael fetch is primary fix when search omits link'
      : '  (direct path still works)'
  )

  if (failures) {
    console.error(`\n${failures} check(s) failed`)
    process.exit(1)
  }
  console.log('\nAll checks passed.')
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
