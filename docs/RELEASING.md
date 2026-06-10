# Releasing MovieBox

MovieBox uses [Sparkle](https://sparkle-project.org/) for in-app updates. Releases are published on [GitHub Releases](https://github.com/Rahuletto/moviebox/releases); the app reads `appcast.xml` on the `main` branch.

Sparkle **update signatures** (EdDSA) are configured. **Apple Developer ID** is optional — see [Without Developer ID](#without-developer-id) below.

## One-time setup (done in repo)

- `SUPublicEDKey` is in `App/MovieBox/Info.plist`
- GitHub Actions secret `SPARKLE_PRIVATE_KEY` is set on `Rahuletto/moviebox`

To regenerate keys on a new Mac:

```bash
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle*' -name generate_keys 2>/dev/null | head -1)"
"$SPARKLE_BIN/generate_keys"
# Update Info.plist with the printed public key, then:
"$SPARKLE_BIN/generate_keys" -x .sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY --repo Rahuletto/moviebox < .sparkle-private-key
rm -f .sparkle-private-key
```

## Without Developer ID

You do **not** need the paid Apple Developer Program for Sparkle or GitHub Releases.

| What | Without Dev ID |
|------|----------------|
| **GitHub Release zip** | CI builds and uploads `MovieBox.zip` |
| **Sparkle feed** | `appcast.xml` signed with EdDSA via `SPARKLE_PRIVATE_KEY` |
| **First install** | Users download from Releases → may need **right-click → Open** (Gatekeeper) |
| **In-app update** | Works best when the installed app and the update are built with the **same** ad-hoc/local signature (e.g. both from CI). Mixed Xcode Run vs CI zip can fail to replace the app. |
| **Notarization** | Not available — expect stricter Gatekeeper warnings for strangers |

**Practical approach:** ship only via **GitHub Releases + Sparkle**; tell users to open the app once from the downloaded zip. Avoid promising “one-click update” to random internet users without Dev ID.

## Cutting a release

1. Bump versions in Xcode (**MovieBox** target):
   - **Marketing Version** → e.g. `1.0.0`
   - **Current Project Version** → build number (integer, must increase every release)

2. Commit, tag, and push:

```bash
git add -A
git commit -m "chore: release v1.0.0"
git tag v1.0.0
git push origin main
git push origin v1.0.0
```

3. Watch **Actions → Release** on GitHub. It will build, sign the zip with Sparkle, update `appcast.xml`, and create the release.

## Trigger workflows manually

Both CI workflows support **Run workflow** in GitHub (**Actions** → pick workflow → **Run workflow**) and the `gh` CLI.

### Swift build (compile check)

```bash
# GitHub UI: Actions → Swift build → Run workflow
gh workflow run swift-build.yml --repo Rahuletto/moviebox
```

### Release (build zip + appcast + GitHub Release)

Tag push (above) is the normal path. To run a release **without** pushing a tag first:

```bash
# GitHub UI: Actions → Release → Run workflow → enter version (e.g. 1.0.0)
gh workflow run release.yml --repo Rahuletto/moviebox -f version=1.0.0

# Optional: upload release but skip committing appcast.xml to main
gh workflow run release.yml --repo Rahuletto/moviebox -f version=1.0.0 -f skip_appcast_push=true
```

Helper script from the repo root:

```bash
chmod +x scripts/gh-workflow.sh   # once
./scripts/gh-workflow.sh build
./scripts/gh-workflow.sh release 1.0.0
```

Watch progress:

```bash
gh run list --workflow=release.yml --repo Rahuletto/moviebox
gh run watch --repo Rahuletto/moviebox
```

## Manual release (without CI)

```bash
cd App
# Build Release .app (Product → Archive, or xcodebuild -configuration Release)
ditto -c -k --sequesterRsrc --keepParent path/to/MovieBox.app build/MovieBox.zip

SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle*' -name generate_keys 2>/dev/null | head -1)"
DIR="$(dirname "$SPARKLE_BIN")"
"$DIR/sign_update" build/MovieBox.zip
"$DIR/generate_appcast" build -o ../appcast.xml
```

Upload `MovieBox.zip` to a GitHub Release and commit `appcast.xml` on `main`.

## Appcast URL

`https://raw.githubusercontent.com/Rahuletto/moviebox/main/appcast.xml`

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| “Update not found” | `appcast.xml` empty or installed build ≥ release |
| Signature error | `SUPublicEDKey` ≠ `SPARKLE_PRIVATE_KEY` pair |
| Update downloads but won’t install | Dev ID mismatch; install from same CI build chain |
| Gatekeeper blocks app | Expected without notarization — Open from Finder |
