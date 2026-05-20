import { describe, expect, it } from 'vitest'
import {
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

  it('returns null when critics score is missing', () => {
    expect(parseCriticsScoreFromHtml('<html></html>')).toBeNull()
  })
})
