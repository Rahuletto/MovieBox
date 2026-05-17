import { USER_AGENT } from './utils'

function normalizeHash(raw: string): string | null {
  const hash = raw.trim().toLowerCase()
  if (/^[a-f0-9]{40}$/.test(hash)) return hash
  return null
}

function torrentFileURLs(hash: string): string[] {
  const upper = hash.toUpperCase()
  return [
    `https://itorrents.org/torrent/${upper}.torrent`,
    `https://itorrents.org/torrent/${hash}.torrent`,
    `http://torrage.info/torrent.php?h=${hash}`,
    `https://torra.to/api/v1/torrents/${hash}`,
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
      const buf = await res.arrayBuffer()
      if (buf.byteLength < 64) continue
      return new Uint8Array(buf)
    } catch {
      continue
    }
  }
  return null
}
