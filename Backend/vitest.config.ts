import { readFileSync } from 'node:fs'
import { defineWorkersConfig } from '@cloudflare/vitest-pool-workers/config'

function readDevVar(name: string): string | undefined {
  try {
    const lines = readFileSync('.dev.vars', 'utf8').split('\n')
    for (const line of lines) {
      if (line.startsWith(`${name}=`)) {
        return line.slice(name.length + 1).trim()
      }
    }
  } catch {
    return undefined
  }
  return undefined
}

const tmdbToken = readDevVar('TMDB_TOKEN') ?? process.env.TMDB_TOKEN ?? ''

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: {
          configPath: './wrangler.jsonc',
          environment: {
            APP_SECRET: 'test-secret',
            TMDB_TOKEN: tmdbToken,
            FANART_API_KEY: readDevVar('FANART_API_KEY') ?? '',
            OMDB_API_KEY: readDevVar('OMDB_API_KEY') ?? '',
          },
        },
      },
    },
  },
})
