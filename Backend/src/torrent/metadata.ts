import { USER_AGENT } from './utils'

function normalizeHash(raw: string): string | null {
  const hash = raw.trim().toLowerCase()
  if (/^[a-f0-9]{40}$/.test(hash)) return hash
  return null
}

/** Bencode torrent files are dictionaries and always start with `d`. */
export function isTorrentFileBytes(data: Uint8Array): boolean {
  return data.byteLength >= 64 && data[0] === 0x64
}

function torrentFileURLs(hash: string): string[] {
  const upper = hash.toUpperCase()
  return [
    `https://itorrents.org/torrent/${upper}.torrent`,
    `https://itorrents.org/torrent/${hash}.torrent`,
    // High-speed secure proxy fallback to bypass ISP/school SNI domain blocks
    `https://api.codetabs.com/v1/proxy/?quest=https://itorrents.org/torrent/${upper}.torrent`,
    `https://api.codetabs.com/v1/proxy/?quest=https://itorrents.org/torrent/${hash}.torrent`,
    `http://itorrents.org/torrent/${hash}`,
    `http://itorrents.org/torrent/${upper}.torrent`,
  ]
}

/** Fetch raw .torrent bytes from public caches (tries every known mirror). */
export async function fetchTorrentFileBytes(infoHash: string): Promise<Uint8Array | null> {
  const hash = normalizeHash(infoHash)
  if (!hash) return null

  for (const url of torrentFileURLs(hash)) {
    try {
      const res = await fetch(url, {
        headers: { 'User-Agent': USER_AGENT, Accept: 'application/x-bittorrent,*/*' },
        redirect: 'follow',
        cf: { cacheTtl: 3600 },
      })
      if (!res.ok) continue
      const buf = new Uint8Array(await res.arrayBuffer())
      if (!isTorrentFileBytes(buf)) continue
      return buf
    } catch {
      continue
    }
  }
  return null
}
