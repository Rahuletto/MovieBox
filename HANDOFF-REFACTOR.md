# Handoff: `refactor` branch → fix metadata networking

**Audience:** Next agent taking over this work.  
**Branch:** `refactor` (1 commit ahead of `main`: `24d6776 refactor changes`, plus **uncommitted** networking tweaks).  
**User constraint:** Do **not** wholesale-revert the refactor. **`main` worked** with production Worker URL. Fix forward.

---

## Executive summary

| Area | Status |
|------|--------|
| App modularization (packages, split views) | Done on branch; builds |
| Backend (Zod, tmdb-upstream, trailer-resolve, tests) | Done on branch; unit tests pass; **no redeploy required** for TLS issue |
| Production Worker `https://moviebox-backend.rahulmarban.workers.dev` | **Healthy** — user confirmed `/health` in Safari (`ok: true`, tmdb/fanart/auth configured) |
| Metadata load in app (Home/Catalog/etc.) | **Broken** — TLS / CFNetwork errors, long spinners |
| Root cause (high confidence) | App switched metadata from `URLSession.shared` (worked on `main` / `b441ade`) to custom `CoreMetadata/BackendURLSession` (ephemeral + empty proxy dict). Safari uses system session → works; app uses broken session → fails. |
| Sandbox / Info.plist | **Unchanged** vs `main` — unlikely the regression |

---

## What was refactored (keep all of this)

### Swift app architecture

1. **Deleted monolith** `App/MovieBox/RootView.swift` (~1300 lines) → split into:
   - `App/MovieBox/Application/` — `AppShellView`, `RootContentView`, `RootTabStack`, `RootView`, `WatchHistoryTracking`, `AppErrorBanner`
   - `App/MovieBox/Views/` — `HomeView`, `Catalog/CatalogView`, `Downloads/`, `Detail/*`, `Search/`, `Browse/`
   - `App/MovieBox/Utilities/` — layout, diagnostics, download UI helpers
   - `App/MovieBox/Components/RetryCard.swift`, etc.

2. **New Swift packages**
   - `App/MovieBoxCore/` — `CatalogLoader`, `MetadataSettings`, `AppSettings+MovieBox`, `TorrentBackendSync`, `AppBootstrap`, logging
   - `App/MovieBoxDetail/` — `MovieDetailLoader`, torrent search orchestration

3. **Demo / MVP removed**
   - `DemoPlayback.swift`, `StreamTestCatalog.swift`, `DemoDetailView.swift`, `sample-en.srt`, `Common.swift`

4. **CoreStreaming** — substantial torrent/DHT/download work (not the metadata bug):
   - `TorrentMetadataBackend`, `DownloadPersistence`, `TorrentFileAssembler`, protocol tests, etc.
   - `CoreStreaming/BackendURLSession.swift` — **keep**; used for torrent API only (same pattern as before)

5. **DEBUG dev config (new)**
   - `App/MovieBox/Configuration/DevelopmentSettings.swift` — auto-fills Worker URL + app token when Settings empty
   - `DevelopmentSecrets.swift.example` — copy to gitignored `DevelopmentSecrets.swift` with `APP_SECRET` from `Backend/.dev.vars`

### Backend (TypeScript Worker)

- `Backend/src/schemas.ts` + `validate.ts` — Zod request validation
- `Backend/src/tmdb-upstream.ts` — TMDB URL builder (replaces mutating `c.req.url` on request)
- `Backend/src/trailer-resolve.ts` — real trailer resolution (replaced mock)
- More unit tests; `vitest.unit.config.ts`
- `Backend/scripts/deploy.sh`, oxlint/oxfmt in package scripts
- **`wrangler.jsonc` `compatibility_date`** was briefly changed then **reverted** to match production

**Important:** Client-side TLS failures happen **before** HTTP hits the Worker. Backend refactor is **not** the cause of “TLS error” in the macOS app. User’s Safari `/health` proves deployed backend is fine.

---

## What is broken

### Symptom

- Home / Catalog show “Loading movies…” for a long time, then errors like:
  - `A TLS error caused the secure connection to fail`
  - `kCFErrorDomainCFNetwork error 310` (proxy connection failure)
- Settings show backend mode: `https://moviebox-backend.rahulmarban.workers.dev` + app token
- **Safari** `https://moviebox-backend.rahulmarban.workers.dev/health` → **works** (user screenshot, May 2026)

### Code-level bugs (fix these)

1. **`MetadataClient` session regression** — [`App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift`](App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift)

   On **`main` / `b441ade`**:
   ```swift
   public init(mode: MetadataEndpointMode? = nil, session: URLSession = .shared, ...)
   ```

   On **`refactor` (current)**:
   ```swift
   } else if case .backend = mode {
       self.session = BackendURLSession.urlSession  // ← regression
   } else {
       self.session = .shared
   }
   ```

   New file: [`App/CoreMetadata/Sources/CoreMetadata/BackendURLSession.swift`](App/CoreMetadata/Sources/CoreMetadata/BackendURLSession.swift) — ephemeral session + `connectionProxyDictionary = [:]`. **Do not use this for metadata.**

2. **`BackendReachability` uses the same bad session** — [`App/MovieBoxCore/Sources/MovieBoxCore/BackendReachability.swift`](App/MovieBoxCore/Sources/MovieBoxCore/BackendReachability.swift) (untracked/new)
   - Health check can fail in-app while Safari succeeds
   - Also sends `X-MovieBox-Token` on `/health` unnecessarily (`/health` is public)

3. **Incomplete `resolveMode` wiring** — [`App/MovieBoxCore/Sources/MovieBoxCore/MetadataSettings.swift`](App/MovieBoxCore/Sources/MovieBoxCore/MetadataSettings.swift)
   - `HomeView` uses `await MetadataSettings.resolveMode` (partial)
   - `CatalogView`, `SearchView`, `GenreResultsView`, `AsyncLogoView` still use sync `MetadataSettings.mode()` → always `.backend` when URL+token set
   - Bug: when health fails and no TMDB token, `resolveMode` still returns `.backend` (line ~28) instead of `nil`

4. **`DevelopmentSettings`** — new on branch; auto-writes Worker URL on first DEBUG launch. User **did** use production Worker successfully before; ensure `DevelopmentSecrets.appToken` matches deployed `APP_SECRET` (wrong token → 401, not TLS).

### What is NOT broken (don’t blame these)

- VPN (user has none)
- Worker down (Safari `/health` OK)
- App Sandbox / ATS — [`Info.plist`](App/MovieBox/Info.plist) and [`MovieBox.entitlements`](App/MovieBox/MovieBox.entitlements) are **byte-identical** to `main` for network keys (`NSAllowsArbitraryLoads`, `com.apple.security.network.client`)

---

## My take (prior agent)

1. **Trust the Safari test.** Backend is reachable; fix the **app’s URLSession**, not Cloudflare.
2. **Restore `URLSession.shared` for all metadata + health checks** — match `main` / commit `b441ade` (`feat: backend deployment`).
3. **Keep** `CoreStreaming/BackendURLSession` for torrent metadata only.
4. **Finish** async `resolveMode` everywhere OR drop it if shared session fixes everything (health should then pass).
5. **Do not redeploy** backend unless user asks.
6. **Do not commit** unless user asks (they wanted to commit `refactor` themselves).

Planned fix doc: `.cursor/plans/` or user-approved plan “Fix metadata networking” — todos: restore shared session, fix resolveMode, wire views, verify build.

---

## Instructions: compare with `main` (ground truth)

`main` is the last known-good app behavior for metadata via production Worker.

### 1. Branch and diff overview

```bash
cd /Users/marban/Documents/Coding/moviebox
git fetch origin
git checkout refactor
git log main..refactor --oneline
git diff main --stat
git diff main --name-only | less
```

### 2. Metadata networking (most important)

```bash
# MetadataClient init + session
git diff main -- App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift

# What main had (working) — same as b441ade for networking
git show main:App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift | sed -n '220,250p'

# New broken file (only on refactor)
cat App/CoreMetadata/Sources/CoreMetadata/BackendURLSession.swift

# Torrent session (unchanged intent — compare only if curious)
git diff main -- App/CoreStreaming/Sources/CoreStreaming/BackendURLSession.swift
```

**Expect:** `main` has no `CoreMetadata/BackendURLSession.swift`; `MetadataClient` always defaults to `.shared`.

### 3. Settings / dev auto-config (new on refactor)

```bash
git diff main -- App/MovieBox/Configuration/
git diff main -- App/MovieBoxCore/Sources/MovieBoxCore/MetadataSettings.swift
git diff main -- App/MovieBoxCore/Sources/MovieBoxCore/AppSettings+MovieBox.swift
git show main:App/MovieBox/Views/HomeView.swift 2>/dev/null | head -50  # path may be RootView on main
```

On **main**, there is no `DevelopmentSettings.swift`. Refactor adds DEBUG auto-fill of Worker URL.

### 4. View wiring (who calls metadata)

```bash
rg "MetadataSettings\.(mode|resolveMode|client)" App/
rg "MetadataClient\(" App/
git diff main -- App/MovieBox/Views/HomeView.swift App/MovieBox/Views/Catalog/
```

### 5. Backend (verify logic equivalent; not TLS cause)

```bash
git diff main -- Backend/src/index.ts Backend/src/tmdb-upstream.ts Backend/src/validate.ts
cd Backend && pnpm test
```

TMDB proxy on main mutated `c.req.url`; refactor uses `buildTMDBUpstreamURL()` — same destination URL. Deployed Worker may still run **old** bundle; that’s fine for this bug.

### 6. Plist / sandbox (should be identical)

```bash
git diff main -- App/MovieBox/Info.plist App/MovieBox/MovieBox.entitlements
```

### 7. Build verification

```bash
cd App
xcodebuild -scheme MovieBox -destination 'platform=macOS' build
```

Run app (DEBUG): confirm Home + Catalog load. Optional: log `NSError` domain/code on failure.

### 8. Worker smoke test (mimics app HTTP calls)

From `Backend/`:

```bash
pnpm smoke
# local wrangler:
MOVIEBOX_WORKER_URL=http://127.0.0.1:8787 pnpm smoke
```

Script: [`Backend/scripts/smoke-worker.mjs`](Backend/scripts/smoke-worker.mjs)

- Uses `X-MovieBox-Token` on all `/api/*` routes (same as `MetadataClient`, torrent search, etc.)
- No token on `/health` and `/img` (same as app)
- Sample movie: TMDB `550` (Fight Club)
- `api/torrent/metadata` accepts 200 or 404 (placeholder hash)
- Reads `APP_SECRET` from `Backend/.dev.vars` or `APP_SECRET` env

If smoke **passes** but the **macOS app** fails → problem is app `URLSession` / Swift wiring, not the Worker.

### 9. Useful commits

| Commit | Note |
|--------|------|
| `main` | Last known-good app |
| `b441ade` | `feat: backend deployment` — metadata used `URLSession.shared` |
| `24d6776` | `refactor changes` on branch |
| Working tree | Uncommitted: `BackendReachability.swift`, `CoreMetadata/BackendURLSession.swift`, edits to `HomeView`, `MetadataSettings`, `CoreMetadata.swift` |

---

## Fix checklist (for next agent)

- [ ] `MetadataClient`: default `session: URLSession = .shared`; remove `BackendURLSession` branch
- [ ] `BackendReachability`: use `.shared`; GET `/health` without auth header; 8s timeout
- [ ] Delete or unused: `App/CoreMetadata/.../BackendURLSession.swift`
- [ ] `resolveMode`: on health fail + no TMDB token → `nil`, not `.backend`
- [ ] Wire `resolveMode` / async `client` in `CatalogView`, `SearchView`, `GenreResultsView`, `AsyncLogoView`, detail flows
- [ ] Align `HomeView` `metadataMode` display with resolved mode
- [ ] Error strings: no VPN lecture; mention Worker URL + token if TLS persists
- [ ] `xcodebuild` + `cd Backend && pnpm test`
- [ ] **No** `wrangler deploy` unless user asks
- [ ] **No** `git commit` unless user asks

---

## Key paths quick reference

| Purpose | Path |
|---------|------|
| Metadata client | `App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift` |
| Bad metadata session | `App/CoreMetadata/Sources/CoreMetadata/BackendURLSession.swift` |
| Good torrent session | `App/CoreStreaming/Sources/CoreStreaming/BackendURLSession.swift` |
| Mode resolution | `App/MovieBoxCore/Sources/MovieBoxCore/MetadataSettings.swift` |
| Health probe | `App/MovieBoxCore/Sources/MovieBoxCore/BackendReachability.swift` |
| DEBUG settings seed | `App/MovieBox/Configuration/DevelopmentSettings.swift` |
| Catalog load | `App/MovieBoxCore/Sources/MovieBoxCore/CatalogLoader.swift` |
| Worker API | `Backend/src/index.ts` |
| Secrets example | `App/MovieBox/Configuration/DevelopmentSecrets.swift.example` |
| Real secrets | `Backend/.dev.vars` (gitignored) |

**Endpoints**

- Health: `GET https://moviebox-backend.rahulmarban.workers.dev/health` (no auth)
- TMDB proxy: `GET {baseURL}/api/tmdb/movie/popular` + header `X-MovieBox-Token: {APP_SECRET}`
- Title bundle: `GET {baseURL}/api/title/movie/{id}` + same header

---

## Git state at handoff

```
Branch: refactor
Commit: 24d6776 refactor changes (+ local modifications)
vs main: ~132 files changed (large refactor)
Uncommitted:
  M App/CoreMetadata/.../CoreMetadata.swift
  M App/MovieBox/Views/HomeView.swift
  M App/MovieBoxCore/.../MetadataSettings.swift
  ?? App/CoreMetadata/.../BackendURLSession.swift
  ?? App/MovieBoxCore/.../BackendReachability.swift
```

User will commit when ready; prior agent was told not to commit.
