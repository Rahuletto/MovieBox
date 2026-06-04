#!/bin/bash
# Embeds sandbox-safe static ffmpeg/ffprobe (evermeet.cx) with full HLS muxer support.
set -euo pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
  exit 0
fi

DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/MacOS"
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "arm64" ]]; then
  echo "error: MovieBox builds for Apple Silicon (arm64) only; host is ${HOST_ARCH}" >&2
  exit 1
fi
CACHE_ROOT="${BUILD_DIR%/Build/*}/MovieBoxFFmpegStatic"
CACHE_DIR="${CACHE_ROOT}/${HOST_ARCH}"
mkdir -p "${CACHE_DIR}" "${DEST}"

binary_arch() {
  local bin="$1"
  if file "$bin" | grep -q 'arm64'; then
    echo arm64
  elif file "$bin" | grep -q 'x86_64'; then
    echo x86_64
  else
    echo unknown
  fi
}

binary_usable_on_host() {
  local bin="$1"
  [[ "$(binary_arch "$bin")" == arm64 ]]
}

sign_embedded_tool() {
  local path="$1"
  xattr -cr "$path" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "$path"
}

fetch_tool() {
  local name="$1"
  local url="$2"
  local cached="${CACHE_DIR}/${name}"

  if [[ -x "${cached}" ]] && binary_usable_on_host "${cached}"; then
    return 0
  fi

  rm -f "${cached}"
  echo "Downloading static ${name} for ${HOST_ARCH}..."
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  curl -fsSL -JL "${url}" -o "${tmp}/${name}.zip"
  unzip -q -o "${tmp}/${name}.zip" -d "${tmp}"
  install -m 755 "${tmp}/${name}" "${cached}"

  if ! binary_usable_on_host "${cached}"; then
    echo "error: ${name} is $(binary_arch "${cached}") but Apple Silicon (arm64) is required" >&2
    rm -f "${cached}"
    exit 1
  fi
}

fetch_tool ffmpeg "https://evermeet.cx/ffmpeg/get/zip"
fetch_tool ffprobe "https://evermeet.cx/ffmpeg/get/ffprobe/zip"

if ! "${CACHE_DIR}/ffmpeg" -hide_banner -h muxer=hls 2>&1 | grep -q "Apple HTTP Live Streaming"; then
  echo "error: embedded ffmpeg is missing the HLS muxer" >&2
  exit 1
fi

for tool in ffmpeg ffprobe; do
  cp -f "${CACHE_DIR}/${tool}" "${DEST}/${tool}"
  chmod 755 "${DEST}/${tool}"
  sign_embedded_tool "${DEST}/${tool}"
done

echo "Embedded static ffmpeg/ffprobe (${HOST_ARCH}) into ${DEST}"
