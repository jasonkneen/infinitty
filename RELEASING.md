# Releasing infinitty

infinitty ships **signed + notarized from a local Mac**, not from CI (see
[Why not CI](#why-not-ci)). Once set up, a release is one command.

## TL;DR — cut a release

```sh
# 1. bump the version wherever it appears, commit, tag
git tag v0.1.1 && git push origin v0.1.1

# 2. build universal, then sign + notarize + upload — one command
swift build -c release --arch arm64 --arch x86_64
./scripts/ship-signed.sh 0.1.1
```

`ship-signed.sh` finds the Developer ID cert, signs the app + `infinitty-mcp`
with hardened runtime, builds the drag-to-Applications DMG, notarizes both
with Apple, staples the tickets, rebuilds the tarball, and uploads all four
assets to the matching GitHub release. After the first run it needs **zero
prompts** (notary credentials are cached in the Keychain).

If the GitHub release for the tag doesn't exist yet, create it first:

```sh
gh release create v0.1.1 --title "infinitty v0.1.1" --generate-notes
```

## One-time setup

You need three things, once:

1. **A "Developer ID Application" certificate** in your login Keychain.
   Confirm with:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   If it's missing, see [Certificate recovery](#certificate-recovery).
   > Note: "Apple Distribution" is a *different* cert (for the App Store) and
   > **cannot** notarize a directly-distributed app. Only "Developer ID
   > Application" works here.

2. **Notary credentials** cached in the Keychain. `ship-signed.sh` prompts
   for your Apple ID + an [app-specific password](https://appleid.apple.com)
   the first time and stores them as the profile `infinitty`. To (re)do it
   manually:
   ```sh
   xcrun notarytool store-credentials infinitty \
     --apple-id "you@example.com" --team-id SW75ZJJ5R6
   ```

3. **`gh` authenticated** for uploading release assets (`gh auth status`).

## Certificate recovery

**This is what cost an hour once — read this first if signing fails.**

Symptom: `security find-identity` shows no "Developer ID Application" even
though you've had the cert before, and `codesign` says `no identity found`.

Cause: the certificate got removed from the Keychain while its **private key
survived** (orphaned). macOS only lists a signing identity when *both* halves
are present, so it silently vanishes from the list.

Fix — re-import the public cert to re-pair it with the surviving key:

```sh
security import ~/.infinitty-signing/developerID_application.cer
security find-identity -v -p codesigning | grep "Developer ID Application"
```

A backup of the cert lives at `~/.infinitty-signing/`. If that's gone too,
regenerate one (the private key `~/.infinitty-signing/devid.key` + CSR are
there): upload `devid.csr` at
<https://developer.apple.com/account/resources/certificates/add> → **Developer
ID Application** → download the `.cer` → `security import` it.

## npm package

`@jasonkneen/infinitty` is a thin installer that downloads the release
binaries. Publish after the GitHub release exists:

```sh
cd npm
npm version 0.1.1 --no-git-tag-version
npm publish --access public   # needs `npm login` or NPM_TOKEN
```

Users then get:

```sh
npm install -g @jasonkneen/infinitty
infinitty
claude mcp add infinitty -- infinitty-mcp
```

## Verifying a release is clean

Simulate a real download (quarantine flag + Gatekeeper):

```sh
gh release download vX.Y.Z --pattern "Infinitty-*.dmg"
xattr -w com.apple.quarantine "0083;0;Safari;" Infinitty-*.dmg
spctl -a -t open --context context:primary-signature -vv Infinitty-*.dmg
# want: "accepted  source=Notarized Developer ID"
xcrun stapler validate Infinitty-*.dmg   # want: "The validate action worked!"
```

## Scripts

| Script | Does |
| --- | --- |
| `scripts/make-icns.sh` | `assets/icon.png` → `assets/AppIcon.icns` (masks corners) |
| `scripts/make-app.sh <bin-dir> <ver> [out]` | assemble `Infinitty.app` |
| `scripts/make-dmg.sh <app> <ver> [identity]` | drag-to-Applications DMG |
| `scripts/ship-signed.sh <ver>` | the whole release: sign→notarize→staple→upload |

## Why not CI

`.github/workflows/release.yml` builds and tests on every `v*` tag and *would*
sign/notarize if the secrets are set — but GitHub won't allocate a macOS
runner to this account without a billing/spending-limit configured (macOS
minutes cost 10×). Symptom: the job fails at init in seconds with
`runner_id: 0` and no logs. Until billing is enabled, releases are cut
locally with `ship-signed.sh`; the workflow stays as-is for when it's not.
