#!/bin/zsh
# One-command release: preflight → tests → version bump → universal build →
# sign/notarize/DMG/upload (ship-signed.sh) → GitHub release → npm publish → verify.
#
# Prompts only when a human is needed: dirty tree, test failures, first-time
# notary credentials, npm OTP. Every step is idempotent — if anything fails,
# fix it and rerun the same command; completed steps are skipped.
#
# Usage: scripts/release.sh <version>     e.g. scripts/release.sh 0.1.9
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then read "VERSION?Version to release (e.g. 0.1.9): "; fi
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "ERROR: '$VERSION' is not X.Y.Z"; exit 1; }
TAG="v$VERSION"
PKG="@jasonkneen/infinitty"

step() { print; print -P "%F{blue}==>%f %B$1%b"; }
ok()   { print -P "  %F{green}✓%f $1"; }
warn() { print -P "  %F{yellow}!%f $1"; }
die()  { print -P "%F{red}ERROR:%f $1"; exit 1; }

find_bin() {
  BIN=""
  for d in .build/out/Products/Release .build/apple/Products/Release; do
    if [ -x "$d/infinitty" ] && [ -x "$d/infinitty-mcp" ] \
      && [ -x "$d/infinitty-agent" ]; then BIN="$d"; break; fi
  done
}

step "Preflight"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no Developer ID Application cert in Keychain"
npm whoami >/dev/null 2>&1 || die "npm not logged in (run: npm login)"
ok "gh auth, signing cert, npm auth"
xcrun notarytool history --keychain-profile infinitty >/dev/null 2>&1 \
  || die "notary profile 'infinitty' missing"
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  die "working tree must be clean for a release"
fi

step "Tests"
swift test
INFINITTY_PERFORMANCE_GATES=1 swift test --filter PerformanceBudgetTests
ok "tests and isolated performance gates passed"

step "Version bump"
CURRENT=$(cd npm && npm pkg get version | tr -d '"')
if [ "$CURRENT" = "$VERSION" ]; then
  ok "npm/package.json already at $VERSION"
else
  (cd npm && npm version "$VERSION" --no-git-tag-version >/dev/null)
  git add npm/package.json
  git commit -m "npm: bump to $VERSION"
  ok "bumped $CURRENT → $VERSION and committed"
fi

step "Universal release build"
swift build -c release --arch arm64 --arch x86_64
find_bin
[ -n "$BIN" ] || die "built products not found in .build/out or .build/apple"
if [ "$(find Sources -name '*.swift' -newer "$BIN/infinitty" | wc -l)" -gt 0 ]; then
  warn "build cache claims up-to-date but sources are newer — forcing clean rebuild"
  rm -rf .build/out .build/apple
  swift build -c release --arch arm64 --arch x86_64
  find_bin
  [ -n "$BIN" ] || die "clean rebuild produced no binaries"
fi
lipo -archs "$BIN/infinitty" | grep -q arm64 || die "binary is not universal (lipo: $(lipo -archs "$BIN/infinitty"))"
ok "fresh universal binaries in $BIN"

step "Tag + push"
if git rev-parse -q --verify "$TAG" >/dev/null; then
  ok "tag $TAG already exists"
else
  git tag "$TAG"
  ok "tagged $TAG"
fi
git push origin HEAD "$TAG"
ok "pushed branch + tag"

step "GitHub release"
if gh release view "$TAG" >/dev/null 2>&1; then
  ok "release $TAG already exists"
else
  gh release create "$TAG" --title "infinitty $TAG" --generate-notes
  ok "created release $TAG"
fi

step "Sign + notarize + DMG + upload (a few minutes of notarization ahead)"
scripts/ship-signed.sh "$VERSION"

step "npm publish"
if npm view "$PKG@$VERSION" version >/dev/null 2>&1; then
  ok "$PKG@$VERSION already on npm"
else
  (cd npm && npm publish --access public)
  ok "published $PKG@$VERSION"
fi

step "Verify"
gh release view "$TAG" --json assets --jq '.assets[].name' | sed 's/^/  asset: /'
print "  npm: $PKG@$(npm view "$PKG@$VERSION" version)"
print
print -P "%BDONE — $TAG shipped: signed DMG + tarball on GitHub, $PKG@$VERSION on npm.%b"
