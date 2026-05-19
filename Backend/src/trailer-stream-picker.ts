export interface PipedVideoStream {
  url?: string
  format?: string
  quality?: string
}

export interface PipedStreamsPayload {
  hlsUrl?: string
  hls?: string
  videoStreams?: PipedVideoStream[]
}

/** Prefer MP4/HLS streams AVPlayer can play; never WebM/proxy videoplayback-only picks. */
export function pickTrailerStreamURL(data: PipedStreamsPayload): string | null {
  const streams = data.videoStreams ?? []

  for (const stream of streams) {
    const url = stream.url ?? ''
    const format = stream.format?.toLowerCase() ?? ''
    if (url.includes('odycdn') && url.includes('.mp4') && !format.includes('webm')) {
      return url
    }
  }

  const hls = data.hlsUrl ?? data.hls
  if (hls) return hls
  const candidates: { url: string; score: number }[] = []

  for (const stream of streams) {
    const url = stream.url ?? ''
    if (!url) continue
    const format = stream.format?.toLowerCase() ?? ''
    if (format.includes('webm')) continue

    let score = 0
    const quality = Number(stream.quality ?? 0)

    if (url.includes('odycdn') && url.includes('.mp4')) {
      score += 200
    } else if (format.includes('mp4') || format.includes('mpeg')) {
      score += 80
    } else {
      continue
    }

    if (url.includes('proxy.piped') || url.includes('videoplayback')) score -= 25
    if (url.includes('googlevideo')) score -= 10

    if (quality >= 720 && quality <= 1080) score += 40
    else if (quality >= 480 && quality < 720) score += 25
    else if (quality >= 360 && quality < 480) score += 15
    else if (quality > 1080) score += 5

    score += Math.min(quality, 1080)

    candidates.push({ url, score })
  }

  if (candidates.length === 0) return null
  candidates.sort((a, b) => b.score - a.score)
  return candidates[0]?.url ?? null
}
