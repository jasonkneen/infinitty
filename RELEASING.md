# Releasing infinitty

infinitty ships **signed + notarized from a local Mac**, not from CI (see
[Why not CI](#why-not-ci)). Once set up, a release is one command.

## TL;DR — cut a release

```sh
./scripts/release.sh 0.2.3
```

That is the whole release: preflight → tests → version bump + commit →
universal build → tag + push → GitHub release → `ship-signed.sh` → npm publish
→ verify. Every step is idempotent, so after a failure you fix the cause and
rerun the same command; completed steps report `already …` and skip.

If you only want the signed artifacts (or npm auth is dead — see
[When it breaks](#when-it-breaks)), the underlying two steps are:

```sh
VERSION=0.2.3
swift build -c release --arch arm64 --arch x86_64
./scripts/ship-signed.sh "$VERSION"
```

`ship-signed.sh` finds the Developer ID cert, signs the app plus the bundled
`infinitty-mcp` and `infinitty-agent` executables with hardened runtime and
`scripts/Infinitty.entitlements`, builds the drag-to-Applications DMG,
notarizes both with Apple, staples the tickets, rebuilds the tarball, and
uploads all four assets to the matching GitHub release. After the first run it
needs **zero prompts** (notary credentials are cached in the Keychain).

It uploads to an *existing* release, so if the tag has no release yet:

```sh
gh release create "v$VERSION" --title "infinitty v$VERSION" --generate-notes
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

## When it breaks

Real failures from real releases, with the recovery that worked.

### npm auth is dead, and it blocks the DMG

`npm whoami` returning `E401` has stopped v0.2.0, v0.2.1 and v0.2.2. Treat it as
the normal state, not an anomaly.

It blocks *everything* because preflight is all-or-nothing and dies on the first
failure, in this order: `gh auth` → Developer ID cert → `npm whoami` → notary
profile → clean tree. So a dead npm token stops a DMG that has nothing to do
with npm.

`npm login` is browser-interactive — a human has to run it. To ship without it,
run `release.sh`'s steps by hand in the same order and stop before
`npm publish`:

```sh
VERSION=0.2.3
swift test && INFINITTY_PERFORMANCE_GATES=1 swift test --filter PerformanceBudgetTests
(cd npm && npm version "$VERSION" --no-git-tag-version) && git add npm/package.json
git commit -m "npm: bump to $VERSION"
swift build -c release --arch arm64 --arch x86_64
git tag "v$VERSION" && git push origin HEAD "v$VERSION"
gh release create "v$VERSION" --title "infinitty v$VERSION" --generate-notes
./scripts/ship-signed.sh "$VERSION"
```

Publish npm later, on its own — the tarball and DMG don't depend on it:

```sh
npm login && (cd npm && npm publish --access public)
```

### Notarization "fails" but Apple accepted it

Symptom: `notarytool` dies with
`NSURLErrorDomain Code=-1001 "The request timed out."` and the script stops —
leaving a pushed tag and a live GitHub release with **zero assets**.

The submission itself was fine; only the *status poll* timed out. `ship-signed.sh`
now submits once and polls `notarytool info` itself, retrying failed requests
(10 consecutive failures, or 30 minutes, is fatal), so this shouldn't recur. If
something else strands a release mid-flight, **do not re-notarize** — check the
existing submission and resume:

```sh
xcrun notarytool info <submission-id> --keychain-profile infinitty   # want: Accepted

xcrun stapler staple "Infinitty-$VERSION.dmg" && xcrun stapler validate "Infinitty-$VERSION.dmg"
shasum -a 256 "Infinitty-$VERSION.dmg" > "Infinitty-$VERSION.dmg.sha256"
gh release upload "v$VERSION" "Infinitty-$VERSION.dmg" "Infinitty-$VERSION.dmg.sha256" --clobber

ditto -c -k --keepParent dist/Infinitty.app notarize-app.zip
xcrun notarytool submit notarize-app.zip --keychain-profile infinitty --wait
xcrun stapler staple dist/Infinitty.app

STAGE="infinitty-$VERSION"; rm -rf pkg; mkdir -p "pkg/$STAGE"
cp -R dist/Infinitty.app "pkg/$STAGE/"; cp dist/infinitty-mcp dist/infinitty-agent "pkg/$STAGE/"
cp -R shell-integration "pkg/$STAGE/"; cp infinitty.conf.example README.md LICENSE "pkg/$STAGE/"
tar -czf "infinitty-$VERSION-macos.tar.gz" -C pkg "$STAGE"
shasum -a 256 "infinitty-$VERSION-macos.tar.gz" > "infinitty-$VERSION-macos.tar.gz.sha256"
gh release upload "v$VERSION" "infinitty-$VERSION-macos.tar.gz" "infinitty-$VERSION-macos.tar.gz.sha256" --clobber
```

Upload each asset as soon as it's ready rather than batching all four at the
end — it limits how much a late failure can strand.

### "working tree must be clean" with a clean tree

Usually a stale `.git/index.lock` from a killed git process; it also makes
`git add` fail with `Unable to create '.git/index.lock': File exists`. Check the
timestamp and that no git process is alive before removing it:

```sh
ls -l .git/index.lock && ps aux | grep '[g]it '
rm -f .git/index.lock
```

### The test suite crashes only during a release

The full `swift test` run SIGSEGVs non-deterministically under load, and
`release.sh` runs it under `set -e` — a crash aborts the release with no prompt.
Every suite passes in isolation. Rerun; if one suite is implicated, confirm it
with `swift test --filter <SuiteName>`.

### Build products aren't where a script looks

Newer SwiftPM writes universal products to `.build/out/Products/Release`, older
to `.build/apple/Products/Release`. Every script probes both — match that if you
add one. And never pipe `swift build`/`swift test` into `tail`: the pipeline's
exit code is `tail`'s, which hides the failure. Redirect to a log and check `$?`.

The `x86_64 architecture is deprecated for your deployment target` warning
during a universal build is expected and harmless.

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
npm version 0.2.3 --no-git-tag-version
npm publish --access public   # needs `npm login` or NPM_TOKEN
```

`release.sh` does this for you, but the token expires often enough that the
GitHub release and the npm package regularly ship apart — see
[npm auth is dead](#npm-auth-is-dead-and-it-blocks-the-dmg). Publishing late is
fine; the package only downloads the release binaries, so the tag must exist
first either way.

Users then get:

```sh
npm install -g @jasonkneen/infinitty
infinitty
claude mcp add infinitty -- infinitty-mcp
infinitty-agent run -- claude
```

The npm package and release tarball expose the same provider-neutral helper;
`infinitty-agent run -- <cli>` preserves the wrapped CLI's process/TTY
lifecycle, while `infinitty-agent context --format plain` is suitable for
provider hooks and plugins.

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
| `scripts/release.sh <ver>` | **the entire release**, preflight → npm publish; idempotent, rerunnable |
| `scripts/ship-signed.sh <ver>` | artifacts only: sign app + MCP/helper → notarize → staple → DMG/tarball → upload |
| `scripts/make-icns.sh` | `assets/icon.png` → `assets/AppIcon.icns` (masks corners) |
| `scripts/make-app.sh <bin-dir> <ver> [out]` | assemble `Infinitty.app` |
| `scripts/make-dmg.sh <app> <ver> [identity]` | drag-to-Applications DMG |
| `scripts/Infinitty.entitlements` | the entitlements every signature must carry (Apple Events, mic/camera, JIT) |

## Why not CI

`.github/workflows/release.yml` builds and tests on every `v*` tag and *would*
sign/notarize if the secrets are set — but GitHub won't allocate a macOS
runner to this account without a billing/spending-limit configured (macOS
minutes cost 10×). Symptom: the job fails at init in seconds with
`runner_id: 0` and no logs. Until billing is enabled, releases are cut
locally with `ship-signed.sh`; the workflow stays as-is for when it's not.
