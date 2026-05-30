
/** Retry transient Worker fetch failures (common in wrangler dev / workerd). */

const DEFAULT_BACKOFF_MS = [150, 400, 900]

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export function isRetryableFetchError(error: unknown): boolean {
  if (!(error instanceof Error)) return false
  const err = error as Error & { retryable?: boolean; code?: number }
  if (err.retryable === true) return true
  const msg = err.message.toLowerCase()
  return (
    msg.includes('network connection lost') ||
    msg.includes('connection reset') ||
    msg.includes('socket hang up') ||
    msg.includes('timed out') ||
    msg.includes('econnreset') ||
    msg.includes('fetch failed')
  )
}

function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500
}

export function isLocalWorkerRequest(requestURL: string): boolean {
  try {
    const host = new URL(requestURL).hostname
    return host === '127.0.0.1' || host === 'localhost' || host === '[::1]' || host === '::1'
  } catch {
    return false
  }
}

export async function fetchWithRetry(
  input: RequestInfo | URL,
  init?: RequestInit,
  options?: { retries?: number; backoffMs?: number[] }
): Promise<Response> {
  const maxAttempts = (options?.retries ?? 3) + 1
  const backoff = options?.backoffMs ?? DEFAULT_BACKOFF_MS
  let lastError: unknown

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      const response = await fetch(input, init)
      if (isRetryableStatus(response.status) && attempt < maxAttempts - 1) {
        await sleep(backoff[attempt] ?? 500)
        continue
      }
      return response
    } catch (error) {
      lastError = error
      if (attempt >= maxAttempts - 1 || !isRetryableFetchError(error)) {
        throw error
      }
      await sleep(backoff[attempt] ?? 500)
    }
  }

  throw lastError instanceof Error ? lastError : new Error('fetchWithRetry failed')
}
