import { kvGet, kvPut } from './kv-cache'

/** Soft cap on SubDL API search calls per hour (shared across all users). */
const SUBDL_SEARCH_QUOTA_PER_HOUR = 120

export class SubdlQuotaExceededError extends Error {
  constructor() {
    super('SubDL hourly quota reached')
    this.name = 'SubdlQuotaExceededError'
  }
}

export async function acquireSubdlSearchSlot(
  kv: KVNamespace
): Promise<{ allowed: boolean; remaining: number }> {
  const hour = Math.floor(Date.now() / (60 * 60 * 1000))
  const key = `subdl:quota:search:${hour}`
  const current = Number.parseInt((await kvGet(kv, key)) ?? '0', 10) || 0

  if (current >= SUBDL_SEARCH_QUOTA_PER_HOUR) {
    return { allowed: false, remaining: 0 }
  }

  await kvPut(kv, key, String(current + 1), { expirationTtl: 60 * 60 * 2 })
  return { allowed: true, remaining: Math.max(0, SUBDL_SEARCH_QUOTA_PER_HOUR - current - 1) }
}
