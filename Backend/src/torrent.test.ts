import { describe, it, expect } from 'vitest'
import { parse1337xSearchRows } from './torrent/indexers/x1337'

describe('parse1337xSearchRows', () => {
  it('extracts torrent rows from search HTML', () => {
    const html = `
      <table class="table-list">
        <tbody>
          <tr>
            <td class="coll-1 name"><a href="/torrent/12345/Fight-Club-1999/">Fight Club 1999 1080p</a></td>
            <td class="coll-2 seeds">120</td>
            <td class="coll-3 leeches">12</td>
            <td class="coll-4 size">2.1 GB</td>
          </tr>
        </tbody>
      </table>
    `
    const rows = parse1337xSearchRows(html)
    expect(rows).toHaveLength(1)
    expect(rows[0].path).toBe('/torrent/12345/Fight-Club-1999/')
    expect(rows[0].seeders).toBe(120)
  })
})
