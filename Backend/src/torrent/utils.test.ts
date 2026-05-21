import { describe, expect, it } from 'vitest'
import { sanitizeQuery } from './utils'

describe('sanitizeQuery', () => {
  it('appends year when missing from the title', () => {
    expect(sanitizeQuery('Fight Club', 1999)).toBe('Fight Club 1999')
  })

  it('does not duplicate year when client already included it in q', () => {
    expect(sanitizeQuery('Fight Club 1999', 1999)).toBe('Fight Club 1999')
    expect(sanitizeQuery('Project Hail Mary 2026', 2026)).toBe('Project Hail Mary 2026')
  })

  it('repairs a trailing duplicate year already present in q', () => {
    expect(sanitizeQuery('Fight Club 1999 1999', 1999)).toBe('Fight Club 1999')
  })

  it('collapses extra whitespace', () => {
    expect(sanitizeQuery('  Project   Hail  Mary  ', 2026)).toBe('Project Hail Mary 2026')
  })

  it('leaves title unchanged when year param is absent', () => {
    expect(sanitizeQuery('Fight Club 1999', null)).toBe('Fight Club 1999')
  })

  it('appends release year when the title is only a different year token', () => {
    expect(sanitizeQuery('2010', 1984)).toBe('2010 1984')
    expect(sanitizeQuery('1917', 2019)).toBe('1917 2019')
  })

  it('does not duplicate when a year-only title matches the release year', () => {
    expect(sanitizeQuery('2010', 2010)).toBe('2010')
  })
})
