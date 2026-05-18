#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORKER_URL="${MOVIEBOX_WORKER_URL:-https://moviebox-backend.rahulmarban.workers.dev}"

if [[ ! -f .dev.vars ]]; then
  echo "error: Backend/.dev.vars missing (need APP_SECRET, TMDB_TOKEN, FANART_API_KEY)" >&2
  exit 1
fi

echo "→ Syncing secrets from .dev.vars …"
pnpm exec wrangler secret bulk .dev.vars

echo "→ Deploying worker …"
pnpm exec wrangler deploy --minify

echo "→ Waiting for edge propagation …"
sleep 4

APP_SECRET="$(grep '^APP_SECRET=' .dev.vars | cut -d= -f2-)"

for attempt in 1 2 3 4 5; do
  health_code="$(curl -s -o /tmp/moviebox-health.json -w '%{http_code}' "${WORKER_URL}/health" || true)"
  if [[ "$health_code" == "200" ]]; then
    echo "✓ /health OK"
    break
  fi
  echo "  health attempt $attempt: HTTP $health_code (retrying…)"
  sleep 2
done

if [[ "$health_code" != "200" ]]; then
  echo "error: /health failed after deploy" >&2
  exit 1
fi

api_code="$(curl -s -o /tmp/moviebox-config.json -w '%{http_code}' \
  -H "X-MovieBox-Token: ${APP_SECRET}" \
  "${WORKER_URL}/api/config" || true)"

if [[ "$api_code" != "200" ]]; then
  echo "error: /api/config returned HTTP $api_code (check APP_SECRET on Worker)" >&2
  exit 1
fi

tmdb_code="$(curl -s -o /tmp/moviebox-tmdb.json -w '%{http_code}' \
  -H "X-MovieBox-Token: ${APP_SECRET}" \
  "${WORKER_URL}/api/tmdb/movie/popular?page=1" || true)"

if [[ "$tmdb_code" != "200" ]]; then
  echo "error: /api/tmdb/movie/popular returned HTTP $tmdb_code (check TMDB_TOKEN secret)" >&2
  exit 1
fi

echo "✓ /api/config OK"
echo "✓ /api/tmdb/movie/popular OK"
echo ""
echo "Deployed: ${WORKER_URL}"
echo "Use this URL + APP_SECRET from .dev.vars in MovieBox → Settings → Backend Proxy."
