#!/usr/bin/env node
/**
 * Purge MovieBox backend KV caches via authenticated endpoint.
 *
 * Usage:
 *   npm run cache:purge
 *   npm run cache:purge -- --scope=prefix --prefix=title:
 *
 * Env overrides:
 *   MOVIEBOX_WORKER_URL=https://moviebox-backend.rahulmarban.workers.dev
 *   APP_SECRET=your_token
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

type CliArgs = {
  scope: 'all' | 'prefix'
  prefix: string
  help?: boolean
}

type DevVars = Record<string, string>

const scriptDir = dirname(fileURLToPath(import.meta.url))
const backendRoot = join(scriptDir, '..')

function loadDevVars(): DevVars {
  try {
    const text = readFileSync(join(backendRoot, '.dev.vars'), 'utf8')
    const out: DevVars = {}
    for (const line of text.split('\n')) {
      const trimmed = line.trim()
      if (!trimmed || trimmed.startsWith('#')) continue
      const i = trimmed.indexOf('=')
      if (i === -1) continue
      out[trimmed.slice(0, i).trim()] = trimmed.slice(i + 1).trim()
    }
    return out
  } catch {
    return {}
  }
}

function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = { scope: 'all', prefix: '' }
  for (const arg of argv) {
    if (arg.startsWith('--scope=')) {
      const value = arg.slice('--scope='.length)
      if (value === 'prefix') args.scope = 'prefix'
      if (value === 'all') args.scope = 'all'
    } else if (arg.startsWith('--prefix=')) {
      args.prefix = arg.slice('--prefix='.length)
    } else if (arg === '--help' || arg === '-h') {
      args.help = true
    }
  }
  return args
}

function usage() {
  console.log(`MovieBox cache purge

Examples:
  npm run cache:purge
  npm run cache:purge -- --scope=prefix --prefix=title:

Options:
  --scope=all|prefix    Purge all known prefixes or one prefix (default: all)
  --prefix=<value>      Required when scope=prefix
`)
}

async function main() {
  const cli = parseArgs(process.argv.slice(2))
  if (cli.help) {
    usage()
    process.exit(0)
  }

  const dev = loadDevVars()
  const base = (process.env.MOVIEBOX_WORKER_URL ?? 'https://moviebox-backend.rahulmarban.workers.dev').replace(/\/+$/, '')
  const token = process.env.APP_SECRET ?? dev.APP_SECRET
  if (!token) {
    console.error('Missing APP_SECRET (env or Backend/.dev.vars).')
    process.exit(1)
  }

  if (cli.scope === 'prefix' && !cli.prefix) {
    console.error('Missing --prefix when --scope=prefix')
    process.exit(1)
  }

  const url = new URL(`${base}/api/cache/purge`)
  url.searchParams.set('scope', cli.scope)
  if (cli.scope === 'prefix') url.searchParams.set('prefix', cli.prefix)

  const response = await fetch(url, {
    method: 'POST',
    headers: { 'X-MovieBox-Token': token },
  })

  const payload: unknown = await response.json().catch(() => ({}))
  if (!response.ok) {
    console.error(`Purge failed (${response.status}):`, payload)
    process.exit(1)
  }

  console.log('Cache purge complete:')
  console.log(JSON.stringify(payload, null, 2))
}

main().catch((error: unknown) => {
  console.error('Purge failed:', error instanceof Error ? error.message : String(error))
  process.exit(1)
})
