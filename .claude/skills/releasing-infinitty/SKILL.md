---
name: releasing-infinitty
description: Use when cutting, resuming, or repairing an infinitty release — bumping the version, building universal binaries, signing/notarizing/stapling, publishing the DMG and tarball to a GitHub release, publishing @jasonkneen/infinitty to npm, or recovering from a failed release (npm E401, notarytool timeout, tag pushed with no assets, "working tree must be clean", Gatekeeper rejection). Also use when installing a locally built Infinitty.app over /Applications for testing.
---

# Releasing infinitty

infinitty ships **signed and notarized from a local Mac**, not from CI. One
command does everything:

```sh
./scripts/release.sh 0.2.3
```

preflight → tests → version bump + commit → universal build → tag + push →
GitHub release → `ship-signed.sh` (sign, notarize, staple, DMG, tarball,
upload) → npm publish → verify.

**Every step is idempotent.** After a failure, fix the cause and rerun the exact
same command — completed steps print `already …` and skip. Never hand-redo a
step to "get past" a failure without first checking whether a rerun would skip
it.

`RELEASING.md` in the repo root is the reference: one-time setup (Developer ID
cert, notary keychain profile `infinitty`, `gh auth`), certificate recovery, the
script table, and why CI is unused. Read it for anything not covered here.

## Before you touch anything

| Check | Command | Blocks |
| --- | --- | --- |
| GitHub auth | `gh auth status` | tag push, release, upload |
| Signing cert | `security find-identity -v -p codesigning \| grep "Developer ID Application"` | everything |
| npm auth | `npm whoami` | **everything** — see below |
| Notary profile | `xcrun notarytool history --keychain-profile infinitty` | notarization |
| Clean tree | `git status --porcelain` | everything |

Run all five *before* starting. Preflight inside `release.sh` is
all-or-nothing and dies on the first failure in exactly that order, so a
problem you could have seen in ten seconds surfaces after you've already
committed a version bump.

## The npm token is usually dead

`npm whoami` returning `E401` has blocked v0.2.0, v0.2.1 and v0.2.2. Assume it
until proven otherwise.

Because npm is checked third in preflight, a dead token blocks the **DMG**,
which has nothing to do with npm. `npm login` is browser-interactive — you
cannot run it. Ask the human to run `! npm login`, or ship without npm.

**Do not** work around this by editing or bypassing preflight. Run the real
steps in the real order and stop before `npm publish`:

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

The GitHub release and the npm package can ship apart; the package only
downloads release binaries, so the tag has to exist first regardless.

## A release stranded mid-flight

Symptom: the tag is pushed, the GitHub release exists, and it has **zero
assets**.

The dangerous instinct is to re-notarize. Don't — Apple may have already
accepted the submission, and resubmitting wastes 5+ minutes and can leave two
live submissions. Find out what actually happened first:

```sh
gh release view "v$VERSION" --json assets --jq '.assets[].name'   # what's missing
xcrun notarytool info <submission-id> --keychain-profile infinitty  # id is in the failure output
```

If it says `Accepted`, the artifact is fine and only stapling/upload remain.
`RELEASING.md` → **When it breaks** → *Notarization "fails" but Apple accepted
it* has the exact resume sequence. Upload each asset the moment it's ready
instead of batching all four.

## Verify the release for real

Logs lie; a signed-looking app with dropped entitlements is the failure mode
that actually reaches users. Check the artifact, not the transcript:

```sh
spctl -a -vvv -t install dist/Infinitty.app     # want: source=Notarized Developer ID
codesign -dv dist/Infinitty.app 2>&1 | grep -E 'Identifier|flags'
#   want: Identifier=com.jasonkneen.infinitty  and  flags=0x10000(runtime)
xcrun stapler validate "Infinitty-$VERSION.dmg"
lipo -archs dist/Infinitty.app/Contents/MacOS/infinitty   # want: x86_64 arm64
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/Infinitty.app/Contents/Info.plist
gh release view "v$VERSION" --json assets --jq '.assets[].name'   # want: 4 assets
```

## Installing a build for the human to test

The human runs `/Applications/Infinitty.app`, **not** `.build/debug/infinitty`.
`swift build` alone changes nothing they can see. When a fix "still doesn't
work," check `ps aux | grep infinitty` and compare the running process's start
time to your build *before* touching code again.

Sign a test install with the **real Developer ID**, never `codesign --sign -`.
An ad-hoc signature changes the code identity from `com.jasonkneen.infinitty`
and drops the hardened runtime, so macOS treats it as a different app and
silently revokes every TCC grant — Full Disk Access, Screen Recording,
Accessibility — along with the entitlements.

```sh
swift build -c release
BINDIR=$(swift build -c release --show-bin-path)
scripts/make-app.sh "$BINDIR" "$VERSION" dist
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
SIGN=(codesign --force --options runtime --timestamp --entitlements scripts/Infinitty.entitlements --sign "$IDENTITY")
"${SIGN[@]}" dist/Infinitty.app/Contents/MacOS/infinitty-mcp
"${SIGN[@]}" dist/Infinitty.app/Contents/MacOS/infinitty-agent
"${SIGN[@]}" dist/Infinitty.app
cp -R /Applications/Infinitty.app /tmp/Infinitty-backup.app   # back up first
/bin/rm -rf /Applications/Infinitty.app && /bin/cp -R dist/Infinitty.app /Applications/
```

Notarization isn't needed for a local install (no quarantine attribute). Use
`/bin/cp` — the shell aliases `cp` to `-i` and the overwrite prompt hangs a
non-interactive run.

Then **tell the human to Cmd-Q and relaunch. Do not quit the app yourself** — it
holds their live terminal sessions.

## Traps

| Trap | What happens | Do instead |
| --- | --- | --- |
| `swift test \| tail` | Pipeline exit code is `tail`'s, so a failed suite looks green | Redirect to a log, echo `$?` |
| Full `swift test` SIGSEGVs | Non-deterministic under load; `set -e` aborts the release | Rerun; confirm the suite alone with `--filter` |
| `.git/index.lock` exists | "working tree must be clean" / `git add` fails, tree is actually clean | `ls -l .git/index.lock && ps aux \| grep '[g]it '`, then remove if stale |
| Hardcoding `.build/apple` | Newer SwiftPM writes to `.build/out` | Probe both, as every script does |
| `local status=` in a zsh script | `status` is read-only in zsh; the function aborts on assignment | Name it anything else |
| `x86_64 ... is deprecated` warning | Nothing — expected on a universal build | Ignore |

## Red flags — stop

- About to re-notarize after a failure → check `notarytool info` first.
- About to edit `release.sh` to skip a preflight check → run the steps by hand instead.
- About to say "released" from script output alone → run the verify block.
- About to hand-redo a step after a failure → rerun `release.sh`; it skips completed work.
