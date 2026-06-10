import { listPipedAPIBases } from './piped-instances'
import { pickTrailerStreamURL as pickPlayableStream } from './trailer-stream-picker'
import { PipedStreamResponseSchema } from './schemas'

/**
 * Resolves a YouTube video id to a direct MP4/HLS URL via public Piped instances.
 * Returns null when no playable stream is found.
 */
export async function resolveTrailerStreamURL(videoKey: string): Promise<string | null> {
  const pipedBases = await listPipedAPIBases()
  for (const base of pipedBases) {
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

      const picked = pickPlayableStream(parsed.data)
      if (picked) return picked
    } catch {
      continue
    }
  }
  return null
}
