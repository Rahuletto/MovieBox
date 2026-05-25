# MoviePlayer

Reusable Swift package for AVPlayer-based playback with MKV/HLS preparation, HDR verification, and optional hardware transcode fallback.

## Targets

| Target | Role |
|--------|------|
| **MoviePlayerUI** | `PlayerState`, `PlayerView`, HUD, subtitles, PiP |
| **MoviePlayerEngine** | `RemuxService`, ffprobe/ffmpeg, HLS cache, HDR validation |
| **MoviePlayerKit** | `MoviePlayerSession` facade |

## Integration

```swift
import MoviePlayerKit

let session = MoviePlayerSession()
let playerState = PlayerState()

// Local file or torrent-exported path
let prepared = try await session.prepareForPlayback(
    inputURL: fileURL,
    cacheKey: "unique-cache-key"
)
playerState.load(url: prepared.playbackURL, title: "Movie", movieId: 1, ...)
```

Embed **ffmpeg** and **ffprobe** in the app bundle (same as MovieBox: `App/Scripts/embed-ffmpeg-tools.sh` → `Contents/MacOS/`).

## Playback preparation tiers

1. **Native passthrough** — `.mp4` / `.mov` / `.m4v` with H.264 or HEVC and AAC/AC-3/E-AC-3. No FFmpeg; AVPlayer opens the file directly.
2. **Lossless HLS** — Same codecs in MKV/AVI/other containers: FFmpeg **`-c copy`** into fMP4 or TS HLS. HDR/DV/Atmos metadata preserved when possible; verified HUD badges after ffprobe of `init.mp4`.
3. **Transcode HLS** (optional, Settings → *Transcode unsupported formats*) — VideoToolbox `hevc_videotoolbox` or `h264_videotoolbox` + AAC. Used for VP9, AV1, DTS, TrueHD, etc. Shows a non-blocking HUD warning; **no** verified HDR/Atmos badges.

Policy: `PlaybackPreparePolicy(allowTranscodeFallback:)` — default **on** in MovieBox.

## HDR settings

| Setting | Default | Effect |
|---------|---------|--------|
| Strict HDR metadata validation | Off | Permissive: warn and play if mastering/CLL missing after remux |
| Transcode unsupported formats | On | Tier 3 fallback when lossless remux is impossible |

## Testing HDR / Atmos (manual)

1. Play a known HDR10 / DV / Atmos MKV; confirm HUD badges only after remux verification (not torrent title).
2. Compare picture on XDR Mac vs QuickTime on the same file.
3. Logs: `~/Library/Logs/MovieBox/moviebox.log` — `[Remux] hdr validate`, `[HDR] AVPlayer track color`.
4. After playback: `ffprobe` on `~/Library/Caches/com.marban.MovieBox/HLS/<cacheKey>/init.mp4`.
5. Atmos: HDMI passthrough (System Settings → Sound) or Spatial Audio on AirPods while playing verified E-AC-3.

## Format coverage (standalone player expectations)

| Input | Typical path | Notes |
|-------|----------------|-------|
| `.mp4` / `.mov` / `.m4v` H.264 or HEVC + AAC/AC-3/E-AC-3 | Native AVPlayer | Best path; HDR/DV when container carries metadata |
| `.mkv` / `.avi` / … same codecs | Lossless HLS remux (`-c copy`) | Requires bundled ffmpeg/ffprobe |
| `.m3u8` / remote HLS (e.g. Apple test streams) | Direct AVPlayer | No remux |
| VP9, AV1, MPEG-2, ProRes, DTS, TrueHD, FLAC, … | Transcode HLS (optional) | Settings / `PlaybackPreparePolicy.allowTranscodeFallback`; not bit-exact |
| Encrypted / FairPlay / Widevine | Not supported | No DRM license path |

**Not “every format” natively** — AVPlayer only decodes Apple-friendly codecs. MoviePlayer’s goal is **broad files in practice** via probe → native → lossless remux → hardware transcode, not magic open-anything without FFmpeg.

## Caveats

- **Not lossless** when transcoding; 4K HDR transcode is slow and uses GPU.
- **Dolby Vision Profile 5** may need future `dovi_tool` rewrap; plain FFmpeg copy/transcode may not match reference DV.
- **Bitmap/ASS subtitles** are not muxed into HLS (`-sn`); use external SRT or future burn-in.
- **DRM** is not supported.
