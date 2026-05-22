import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
    // E2E flow hits a live worker (search + .torrent fetch). Give every test
    // enough headroom for tracker/cache fanout.
    testTimeout: 90_000,
    hookTimeout: 30_000,
    // Tests touch the same upstream services; keep them serial so logs are readable.
    sequence: { concurrent: false },
    pool: 'forks',
  },
})
