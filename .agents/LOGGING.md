# MovieBox logging (for humans and AI agents)

## Log file location

| Platform | Path |
|----------|------|
| macOS | `~/Library/Logs/MovieBox/moviebox.log` |
| Rotated backup | `~/Library/Logs/MovieBox/moviebox.log.1` (when main file exceeds 5 MB) |

Open in Terminal:

```bash
tail -f ~/Library/Logs/MovieBox/moviebox.log
```

Reveal in Finder from the app: **Help → Reveal Logs in Finder**.

## When debugging

1. Reproduce the issue in the app.
2. Read `moviebox.log` (not only in-app “Copy Logs”; the file has the full session).
3. Search for `[ERROR]` and the category tag (`[metadata]`, `[torrent]`, `[download]`, `[player]`, `[storage]`).
4. Cross-check **Settings →** proxy URL, TMDB/backend tokens, and download path.

## Log format

```
[2026-05-19T12:34:56.789Z] [INFO] [app] RootView: Application launched.
[2026-05-19T12:35:01.123Z] [ERROR] [metadata] [Movie detail] The network connection was lost.
```

## In-app API

- `LogStore.shared.log("message")` — info, category `app`
- `LogStore.shared.log(.error, category: "torrent", "…")`
- `LogStore.shared.logError(error, context: "Download sync", category: "download")`

Memory buffer is capped at 2,000 lines to avoid unbounded growth.
