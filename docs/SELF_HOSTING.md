# Self-hosting the MovieBox backend

You run the full API proxy on **your** Cloudflare account and point the macOS app at it.

There is **no** public MovieBox API operated by the project. The URL in some Debug defaults (`moviebox-backend.….workers.dev`) is the maintainer’s **private** Worker — do not use it unless you were given a token; deploy your own instead.

---

## What you need

- [Cloudflare](https://dash.cloudflare.com/sign-up) account (Workers free tier is enough to start)  
- [Bun](https://bun.sh) installed locally  
- API keys:
  - **[TMDB](https://www.themoviedb.org/settings/api)** — required (v3 API key / read access token)  
  - **[Fanart.tv](https://fanart.tv/get-an-api-key/)** — required for logos/art  
  - **[OMDB](http://www.omdbapi.com/apikey.aspx)** — optional (Rotten Tomatoes–style enrichment)  
  - **[SubDL](https://subdl.com/)** — optional (subtitle search)  

---

## Quick start (local dev)

```bash
git clone https://github.com/Rahuletto/moviebox.git
cd moviebox/Backend
cp .dev.vars.example .dev.vars
```

Edit `.dev.vars`:

```env
TMDB_TOKEN=your_tmdb_token
FANART_API_KEY=your_fanart_key
APP_SECRET=pick_a_long_random_string
OMDB_API_KEY=optional
SUBDL_API_KEY=optional
```

Install and run:

```bash
bun install
bun run dev
```

Worker listens at **http://127.0.0.1:8787**.

Verify:

```bash
curl http://127.0.0.1:8787/health
# {"ok":true,"service":"moviebox-backend",...}

curl -H "X-MovieBox-Token: YOUR_APP_SECRET" http://127.0.0.1:8787/api/config
```

### Point the Mac app at it

1. Open **MovieBox → Settings → Metadata**  
2. Enable **Use local backend (wrangler dev)**  
   - Or set Proxy URL to `http://127.0.0.1:8787` and disable “local” if you use a custom host  
3. **App token** — same string as `APP_SECRET` in `.dev.vars`  
4. Save; torrent indexers should load from `/api/config`  

For Debug builds you can also copy `DevelopmentSecrets.swift.example` → `DevelopmentSecrets.swift` and set `appToken` to match.

---

## Deploy to Cloudflare (production)

### 1. Log in to Wrangler

```bash
cd Backend
bunx wrangler login
```

### 2. Create KV (if not using existing namespace)

```bash
bunx wrangler kv namespace create MOVIEBOX_CACHE
```

Copy the `id` into `wrangler.jsonc` under `kv_namespaces` → `binding: MOVIEBOX_CACHE`.

The repo ships with a namespace id for the maintainer’s account; **replace it with yours** for your own deployment.

### 3. Set secrets (never commit these)

```bash
bunx wrangler secret put TMDB_TOKEN
bunx wrangler secret put FANART_API_KEY
bunx wrangler secret put APP_SECRET
# optional:
bunx wrangler secret put OMDB_API_KEY
bunx wrangler secret put SUBDL_API_KEY
```

Local `.dev.vars` is only for `wrangler dev`; production uses dashboard secrets.

### 4. Adjust `wrangler.jsonc` (optional)

| Variable | Default | Meaning |
|----------|---------|---------|
| `APP_ENV` | `production` | Set `development` only on preview |
| `CORS_ORIGIN` | `*` | Restrict to your domain if you add a web client |
| `RATE_LIMIT_MAX_REQUESTS` | `180` | Per-IP API cap per minute |
| `RATE_LIMIT_SUBTITLE_MAX_REQUESTS` | `40` | Subtitle route cap |

### 5. Deploy

```bash
bun run deploy
# or: bunx wrangler deploy --minify
```

Note the URL, e.g. `https://moviebox-backend.<your-subdomain>.workers.dev`.

### 6. Configure the app

- **Proxy URL** — your Worker URL (`https://…`)  
- **Use local backend** — off  
- **App token** — same as production `APP_SECRET`  

Share the token only with devices you control. Anyone with the token can consume your API quota and upstream keys.

---

## API overview

Base URL: your Worker origin.

| Route | Auth | Description |
|-------|------|-------------|
| `GET /health` | No | Liveness |
| `GET /img?u=…` | No | Image proxy (allowlisted hosts) |
| `GET /api/config` | `X-MovieBox-Token` | Indexer catalog for the app |
| `GET /api/torrent/search` | Yes | Torrent search |
| `GET /api/torrent/search/stream` | Yes | SSE search stream |
| `GET /api/torrent/metadata` | Yes | Torrent file metadata |
| `GET /api/title/:kind/:id` | Yes | Movie/TV bundle |
| `GET /api/subtitles/search` | Yes | Subtitle search |
| `GET /api/subtitles/download` | Yes | Subtitle file proxy |
| `GET /api/trailer/resolve` | Yes | Trailer URL |
| `POST /api/cache/purge` | Yes | Clear KV cache (admin) |

Header for authenticated routes:

```http
X-MovieBox-Token: <APP_SECRET>
```

---

## Operations

### Lint & typegen

```bash
bun run lint:strict
bun run cf-typegen   # refresh worker-configuration.d.ts after wrangler.jsonc changes
```

### Purge cache

```bash
curl -X POST -H "X-MovieBox-Token: $APP_SECRET" \
  "https://your-worker.workers.dev/api/cache/purge?scope=all"
```

### Costs

- **Workers** — requests + CPU time  
- **KV** — reads/writes for cache and rate limits  
- **Upstream APIs** — TMDB/Fanart/SubDL quotas are yours  

Monitor in the Cloudflare dashboard. Aggressive caching (`MOVIEBOX_CACHE`) reduces TMDB calls.

### Hardening a public instance

If you expose a Worker to the internet (not just yourself):

1. Use a **long random** `APP_SECRET` (32+ bytes).  
2. Tighten `CORS_ORIGIN` if you do not need `*`.  
3. Lower rate limits if you see abuse.  
4. Consider Cloudflare **WAF** / IP rules on the zone.  
5. Do not publish your token in screenshots or streams.  
6. Read [PRIVACY.md](../PRIVACY.md) — you become the data operator for your users.

---

## Multiple users (advanced)

The stock backend uses a **single shared** `APP_SECRET`. For family or friends you can:

- Issue the same token to trusted people (simple, no per-user accounting), or  
- Deploy **separate Workers** per person with different secrets, or  
- Fork and add per-token KV lookup if you share one Worker with friends.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `401 unauthorized` | Token mismatch — `APP_SECRET` vs app Settings |
| Empty indexers | Check `/api/config` with curl and token |
| TMDB errors | Invalid `TMDB_TOKEN` or TMDB outage |
| Subtitles rate limited | Wait or raise `RATE_LIMIT_SUBTITLE_MAX_REQUESTS` |
| App still hits old URL | Settings → correct Proxy URL; turn off “local backend” when using deployed Worker |
| KV errors on deploy | Wrong namespace `id` in `wrangler.jsonc` |

---

## Related docs

- [README.md](../README.md) — project overview  
- [PRIVACY.md](../PRIVACY.md) — what data the backend touches  
- [RELEASING.md](RELEASING.md) — macOS app releases (Sparkle)
