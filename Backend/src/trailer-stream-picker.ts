export interface PipedVideoStream {
  url?: string
  format?: string
  quality?: string
  videoOnly?: boolean
  mimeType?: string
}

export interface PipedStreamsPayload {
  hlsUrl?: string
  hls?: string
  videoStreams?: PipedVideoStream[]
}

function parseQuality(raw?: string): number {
  if (!raw) return 0
  const digits = raw.replace(/\D/g, '')
  return Number(digits) || 0
}

function isProxiedHost(url: string): boolean {
  const lower = url.toLowerCase()
  return (
    lower.includes('videoplayback') ||
    lower.includes('proxy.piped') ||
    lower.includes('pipedproxy') ||
    lower.includes('googlevideo.com')
  )
}

function isCandidate(stream: PipedVideoStream): boolean {
  const url = (stream.url ?? '').trim()
  if (!url) return false

  const format = stream.format?.toLowerCase() ?? ''
  const mime = stream.mimeType?.toLowerCase() ?? ''
  const videoOnly = stream.videoOnly ?? true

  if (format.includes('webm') || mime.includes('webm')) return false
  if (videoOnly && isProxiedHost(url)) return false

  if (url.includes('odycdn')) {
    return url.includes('.mp4') || url.includes('m3u8') || format.includes('hls')
  }

  if (format.includes('hls') || url.includes('.m3u8')) {
    return url.includes('odycdn')
  }

  if (format.includes('mp4') || format.includes('mpeg') || mime.includes('mp4')) {
    if (videoOnly && isProxiedHost(url)) return false
    return !videoOnly || !isProxiedHost(url)
  }

  return false
}

function scoreStream(stream: PipedVideoStream): number {
  const url = stream.url ?? ''
  const format = stream.format?.toLowerCase() ?? ''
  const videoOnly = stream.videoOnly ?? true
  let score = 0
  const quality = parseQuality(stream.quality)

  if (url.includes('odycdn') && url.includes('.mp4')) score += 1000
  else if (url.includes('odycdn') && (url.includes('m3u8') || format.includes('hls'))) score += 950
  else if (!videoOnly && (format.includes('mpeg') || format.includes('mp4'))) score += 600

  if (videoOnly) score -= 300

  if (quality >= 720 && quality <= 1080) score += 50
  else if (quality >= 480 && quality < 720) score += 40
  else if (quality >= 360 && quality < 480) score += 30
  else if (quality > 1080) score += 10

  score += Math.min(quality, 1080)
  if (isProxiedHost(url)) score -= 20

  return score
}

/** Prefer muxed MP4/HLS streams AVPlayer can play; never video-only proxy videoplayback URLs. */
export function pickTrailerStreamURL(data: PipedStreamsPayload): string | null {
  const streams = data.videoStreams ?? []
  let best: { url: string; score: number } | null = null

  for (const stream of streams) {
    if (!isCandidate(stream)) continue
    const url = stream.url ?? ''
    const score = scoreStream(stream)
    if (!best || score > best.score) best = { url, score }
  }

  if (best) return best.url

  const hls = data.hlsUrl ?? data.hls
  if (hls && hls.includes('odycdn') && !hls.includes('videoplayback')) return hls

  return null
}
