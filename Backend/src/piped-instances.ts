/** Fallback Piped API bases when the public instances feed is empty or unreachable. */
export const STATIC_PIPED_BASES = [
  'https://api.piped.private.coffee',
  'https://pipedapi.kavin.rocks',
  'https://pipedapi.adminforge.de',
  'https://pipedapi.leptons.xyz',
] as const

interface PipedInstanceRecord {
  api_url?: string
}

/**
 * Merges live instances from TeamPiped with static fallbacks (deduped, API-first).
 */
export async function listPipedAPIBases(): Promise<string[]> {
  const merged: string[] = []

  try {
    const response = await fetch('https://piped-instances.kavin.rocks/', {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(5_000),
    })
    if (response.ok) {
      const instances = (await response.json()) as PipedInstanceRecord[]
      for (const instance of instances) {
        const base = instance.api_url?.trim()
        if (base) merged.push(base.replace(/\/$/, ''))
      }
    }
  } catch {
    // Use static list only.
  }

  for (const base of STATIC_PIPED_BASES) {
    if (!merged.includes(base)) merged.push(base)
  }

  return merged
}
