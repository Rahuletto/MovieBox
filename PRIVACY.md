# Privacy Policy

**Last updated:** May 2026  

This describes how **MovieBox** (macOS app) and the **MovieBox backend** (API proxy in this repo) handle data.

MovieBox is not a video host. Playback and downloads happen on your Mac via torrents; the backend only helps with metadata, images, torrent search, and subtitles.

> Practical transparency, not legal advice. If you run a **public** Worker for others, you are the operator for those users.

---

## Summary

| Component | Who runs it | What leaves your Mac |
|-----------|-------------|----------------------|
| **MovieBox app** | You | Torrent traffic, local files, optional logs |
| **Your backend** | You (self-hosted) | API requests to **your** Worker URL |

There is **no** commercial hosted API from this project. Use [self-hosting](docs/SELF_HOSTING.md) or local `wrangler dev`.

---

## MovieBox app (on your Mac)

### Stored locally

- Library & preferences (SwiftData)  
- Downloads and streaming cache  
- Optional logs: `~/Library/Logs/MovieBox/moviebox.log`  

Watch history and video files are **not** uploaded to a project-operated server by default.

### Network (not via the backend)

- **BitTorrent** — peer traffic when you stream or download  
- Other sites if you open trailers or links in a browser  

### Backend connection (your choice)

**Settings → Metadata:** proxy URL + **app token** (`X-MovieBox-Token`). Treat the token like a password.

---

## The backend (when you self-host)

Cloudflare Worker proxying TMDB, Fanart, indexers, subtitles, images. It does **not** receive torrent video.

- **Auth:** `X-MovieBox-Token` on `/api/*`  
- **Cache:** Cloudflare KV  
- **Rate limits:** per IP (configurable in `wrangler.jsonc`)  
- **Logs:** errors in production; request lines in development. Cloudflare may log at the platform level per [their policy](https://www.cloudflare.com/privacypolicy/).

---

## Maintainer’s personal Worker

The repo may mention a `*.workers.dev` URL in Debug defaults. That deployment is **not** a public service for the community — personal use only, no signup, no SLA. Do not send your data there unless you operate it.

---

## Third-party services

TMDB, Fanart, torrent indexers, subtitle providers, Cloudflare — each has its own terms.

---

## Security

- Rotate `APP_SECRET` if leaked  
- Do not commit `.dev.vars` or `DevelopmentSecrets.swift`  

See [SECURITY.md](SECURITY.md).

---

## Contact

[GitHub issues](https://github.com/Rahuletto/moviebox/issues) on the repo.

Support development: **[GitHub Sponsors](https://github.com/sponsors/Rahuletto)** (optional, no perks or hosted access).
