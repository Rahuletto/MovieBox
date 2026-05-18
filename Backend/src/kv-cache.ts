/** KV helpers that never throw — cache misses on failure so routes stay up in local dev. */

function logKvFailure(op: string, key: string, error: unknown) {
  const message = error instanceof Error ? error.message : String(error)
  console.warn(`[kv] ${op} ${key} failed: ${message}`)
}

export async function kvGet(kv: KVNamespace, key: string): Promise<string | null> {
  try {
    return await kv.get(key)
  } catch (error) {
    logKvFailure('GET', key, error)
    return null
  }
}

export async function kvGetBuffer(kv: KVNamespace, key: string): Promise<ArrayBuffer | null> {
  try {
    return await kv.get(key, 'arrayBuffer')
  } catch (error) {
    logKvFailure('GET', key, error)
    return null
  }
}

export async function kvPut(
  kv: KVNamespace,
  key: string,
  value: string | ArrayBuffer | ReadableStream,
  options?: KVNamespacePutOptions
): Promise<boolean> {
  try {
    await kv.put(key, value, options)
    return true
  } catch (error) {
    logKvFailure('PUT', key, error)
    return false
  }
}
