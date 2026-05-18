# Linting and formatting (Backend)

MovieBox Backend uses **oxlint** and **oxfmt** (not ESLint/Prettier).

## Commands (from `Backend/`)

```bash
pnpm exec oxlint .
pnpm exec oxlint . --fix
pnpm exec oxfmt .
pnpm exec oxfmt --check .
pnpm exec vitest run --config vitest.unit.config.ts
```

Config: [`Backend/oxlint.config.ts`](../Backend/oxlint.config.ts), [`Backend/.oxfmtrc.json`](../Backend/.oxfmtrc.json).

There is **no pnpm workspace** — Backend is a single package.

## CI expectation

- `oxfmt --check` must pass (formatted)
- `oxlint` should have zero errors before merge (warnings triaged over time)
