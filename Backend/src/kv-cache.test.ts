import { describe, expect, it, vi } from 'vitest'
import { kvGet, kvPut } from './kv-cache'

describe('kv-cache', () => {
  it('kvGet returns null when KV throws', async () => {
    const kv = {
      get: vi.fn().mockRejectedValue(new Error('KV GET failed: 500')),
      put: vi.fn(),
    } as unknown as KVNamespace
    await expect(kvGet(kv, 'rate_limit:x')).resolves.toBeNull()
  })

  it('kvPut swallows errors', async () => {
    const kv = {
      get: vi.fn(),
      put: vi.fn().mockRejectedValue(new Error('KV PUT failed')),
    } as unknown as KVNamespace
    await expect(kvPut(kv, 'k', 'v')).resolves.toBe(false)
  })
})
