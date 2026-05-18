import { PipedStreamResponseSchema } from './schemas'

const PIPED_BASES = [
  'https://pipedapi.kavin.rocks',
  'https://pipedapi.adminforge.de',
] as const

/**
 * Resolves a YouTube video id to an HLS URL via public Piped instances.
 * Returns null when no playable stream is found.
 */
export async function resolveTrailerStreamURL(videoKey: string): Promise<string | null> {
  for (const base of PIPED_BASES) {
    const url = `${base}/streams/${encodeURIComponent(videoKey)}`
    try {
      const response = await fetch(url, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(12_000),
      })
      if (!response.ok) continue

      const json: unknown = await response.json()
      const parsed = PipedStreamResponseSchema.safeParse(json)
      if (!parsed.success) continue

      const data = parsed.data
      if (data.hlsUrl) return data.hlsUrl
      if (data.hls) return data.hls

      const stream = data.videoStreams?.find((s) => s.url && s.format?.includes('mp4'))
      if (stream?.url) return stream.url
    } catch {
      continue
    }
  }
  return null
}
