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
})
