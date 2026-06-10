#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-Rahuletto/moviebox}"

usage() {
  cat <<'EOF'
Run MovieBox GitHub Actions workflows from the CLI (requires gh auth login).

Usage:
  scripts/gh-workflow.sh build
  scripts/gh-workflow.sh release <version> [--skip-appcast-push]

Examples:
  scripts/gh-workflow.sh build
  scripts/gh-workflow.sh release 1.0.0
  scripts/gh-workflow.sh release 1.0.1 --skip-appcast-push

Equivalent gh commands:
  gh workflow run swift-build.yml --repo Rahuletto/moviebox
  gh workflow run release.yml --repo Rahuletto/moviebox -f version=1.0.0

Watch a run:
  gh run list --workflow=release.yml --repo Rahuletto/moviebox
  gh run watch --repo Rahuletto/moviebox
EOF
}

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found. Install: https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: not logged in to gh. Run: gh auth login" >&2
  exit 1
fi

cmd="${1:-}"
shift || true

case "$cmd" in
  build)
    echo "→ Triggering Swift build workflow on $REPO"
    gh workflow run swift-build.yml --repo "$REPO" "$@"
    ;;
  release)
    version="${1:-}"
    shift || true
    if [[ -z "$version" ]]; then
      echo "error: release requires a version (e.g. 1.0.0)" >&2
      usage
      exit 1
    fi
    version="${version#v}"
    skip_appcast_push=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --skip-appcast-push)
          skip_appcast_push=true
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          echo "error: unknown option: $1" >&2
          usage
          exit 1
          ;;
      esac
      shift
    done
    echo "→ Triggering Release workflow on $REPO (version=$version)"
    gh workflow run release.yml --repo "$REPO" \
      -f "version=$version" \
      -f "skip_appcast_push=$skip_appcast_push"
    ;;
  -h|--help|help|"")
    usage
    exit 0
    ;;
  *)
    echo "error: unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac

echo ""
echo "→ Recent runs:"
gh run list --repo "$REPO" --limit 3
echo ""
echo "Watch latest: gh run watch --repo $REPO"
