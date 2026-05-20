import { describe, expect, it } from 'vitest'
import {
  extractBestRtVideoFeedUrl,
  extractThePlatformFeedUrl,
  parseCriticsScoreFromHtml,
  resolveRottenTomatoesPath,
  titleToRottenTomatoesSlug,
} from './rotten-tomatoes'

const FIGHT_CLUB_CRITICS = `"criticsScore":{"averageRating":"7.80","certified":true,"likedCount":203,"notLikedCount":46,"ratingCount":249,"reviewCount":249,"score":"82","sentiment":"POSITIVE","reviewsPageUrl":"/m/fight_club/reviews","scorePercent":"82%","title":"Tomatometer"}`

describe('titleToRottenTomatoesSlug', () => {
  it('normalizes titles to RT slugs', () => {
    expect(titleToRottenTomatoesSlug('Fight Club')).toBe('fight_club')
    expect(titleToRottenTomatoesSlug('Project Hail Mary')).toBe('project_hail_mary')
  })
})

describe('resolveRottenTomatoesPath', () => {
  it('prefers exact slug from search html', () => {
    const html = `<a href="https://www.rottentomatoes.com/m/fight_club">Fight Club</a>
      <a href="https://www.rottentomatoes.com/m/fight_club_2023">Other</a>`
    expect(
      resolveRottenTomatoesPath(html, { kind: 'movie', title: 'Fight Club', year: '1999' })
    ).toBe('/m/fight_club')
  })

  it('returns null when search only has unrelated slugs (no random shortest path)', () => {
    const html = `<a href="https://www.rottentomatoes.com/m/tuner">Tuner</a>
      <a href="https://www.rottentomatoes.com/m/other_movie">Other</a>`
    expect(
      resolveRottenTomatoesPath(html, { kind: 'movie', title: 'Michael', year: '2026' })
    ).toBeNull()
  })
})

describe('extractThePlatformFeedUrl', () => {
  it('finds MPX feed URLs with normal slashes', () => {
    const html =
      'href="https://link.theplatform.com/s/ABC/media/xyz123?some=1&other=2"'
    expect(extractThePlatformFeedUrl(html)).toBe(
      'https://link.theplatform.com/s/ABC/media/xyz123?some=1&other=2'
    )
  })

  it('normalizes \\u002F escapes from RT HTML', () => {
    const html =
      'https:\\u002F\\u002Flink.theplatform.com\\u002Fs\\u002FABC\\u002Fmedia\\u002Fxyz?f=1'
    expect(extractThePlatformFeedUrl(html)).toBe(
      'https://link.theplatform.com/s/ABC/media/xyz?f=1'
    )
  })

  it('returns null when absent', () => {
    expect(extractThePlatformFeedUrl('<html></html>')).toBeNull()
  })
})

describe('extractBestRtVideoFeedUrl', () => {
  it('prefers trailer entries that match the requested title', () => {
    const html = `<script id="videos" type="application/json">${JSON.stringify([
      {
        title: 'Marshall: Official Trailer',
        description: '',
        file: 'https://link.theplatform.com/s/NGweTC/media/marshall_trailer?formats=M3U+none',
      },
      {
        title: 'Michael: Final Trailer',
        description: '',
        file: 'https://link.theplatform.com/s/NGweTC/media/michael_final?formats=M3U+none',
      },
      {
        title: 'Michael: Music Clip - Billie Jean',
        description: '',
        file: 'https://link.theplatform.com/s/NGweTC/media/michael_clip?formats=M3U+none',
      },
    ])}</script>`

    expect(extractBestRtVideoFeedUrl(html, 'Michael')).toBe(
      'https://link.theplatform.com/s/NGweTC/media/michael_final?formats=M3U+none'
    )
  })
})

describe('parseCriticsScoreFromHtml', () => {
  it('parses tomatometer breakdown from embedded json', () => {
    const stats = parseCriticsScoreFromHtml(`<html>${FIGHT_CLUB_CRITICS}</html>`)
    expect(stats).toEqual({
      percentage: 82,
      totalReviews: 249,
      freshCount: 203,
      rottenCount: 46,
      averageScore: 7.8,
    })
  })

  it('prefers the criticsScore block with the highest review count', () => {
    const slim = '"criticsScore":{"score":"82","sentiment":"POSITIVE","scorePercent":"82%"}'
    const stats = parseCriticsScoreFromHtml(`<html>${slim}${FIGHT_CLUB_CRITICS}</html>`)
    expect(stats?.percentage).toBe(82)
    expect(stats?.totalReviews).toBe(249)
  })

  it('returns null when critics score is missing', () => {
    expect(parseCriticsScoreFromHtml('<html></html>')).toBeNull()
  })
})
