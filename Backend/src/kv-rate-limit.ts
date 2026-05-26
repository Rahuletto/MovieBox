import { kvGet, kvPut } from './kv-cache'

export type KvRateLimitResult = {
  allowed: boolean
  count: number
  limit: number
}

/**
 * Best-effort per-key counter in KV. Not atomic across isolates — use for abuse
 * throttling only. Retries a few times when concurrent writers race.
 */
export async function consumeKvRateLimit(
  kv: KVNamespace,
  key: string,
  limit: number,
  ttlSeconds: number
): Promise<KvRateLimitResult> {
  const safeLimit = Math.max(1, limit)
  const safeTtl = Math.max(1, ttlSeconds)

  for (let attempt = 0; attempt < 3; attempt++) {
    const raw = await kvGet(kv, key)
    const count = raw ? Number.parseInt(raw, 10) : 0
    const current = Number.isFinite(count) ? count : 0

    if (current >= safeLimit) {
      return { allowed: false, count: current, limit: safeLimit }
    }

    const next = current + 1
    await kvPut(kv, key, String(next), { expirationTtl: safeTtl })

    const verifyRaw = await kvGet(kv, key)
    const verify = verifyRaw ? Number.parseInt(verifyRaw, 10) : next
    if (!Number.isFinite(verify) || verify <= next + 1) {
      return { allowed: true, count: next, limit: safeLimit }
    }
  }

  return { allowed: true, count: 0, limit: safeLimit }
}
