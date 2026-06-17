#!/usr/bin/env bash
#
# Cut a release of ProseKit.
#
# ProseKit is a pure-Swift SwiftPM package — SwiftPM resolves versions straight
# from git tags, so a release is just: sanity-build, push, and create the tag +
# GitHub Release together. (The full test matrix runs in CI on every push.)
#
# Usage:
#   scripts/release.sh <version> [--yes]
#   e.g.  scripts/release.sh 0.1.0
#
# Requirements: an authenticated GitHub CLI (`gh auth login`) and a Swift 6.2
# toolchain, run from a clean checkout.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
ASSUME_YES=0
[ "${2:-}" = "--yes" ] && ASSUME_YES=1

[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version> [--yes]   (e.g. 0.1.0)" >&2; exit 2; }
printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$' \
  || { echo "error: '$VERSION' is not a semantic version (e.g. 0.1.0)" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated (run: gh auth login)." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "error: working tree is dirty — commit or stash first." >&2; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "warning: releasing from '$BRANCH', not 'main'."
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1 \
   || git ls-remote --exit-code --tags origin "$VERSION" >/dev/null 2>&1; then
  echo "error: tag '$VERSION' already exists (locally or on origin)." >&2; exit 1
fi

echo "==> Releasing $VERSION from $BRANCH"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "aborted."; exit 0 ;; esac
fi

# Fast sanity build. PROSEKIT_STRICT turns on warnings-as-errors (gated off by
# default so the package builds as an Xcode SPM dependency). Full tests are CI's job.
PROSEKIT_STRICT=1 swift build

git push origin "$BRANCH"
gh release create "$VERSION" --target "$(git rev-parse HEAD)" --title "$VERSION" --generate-notes

echo
echo "==> Released $VERSION"
echo "    .package(url: \"$(git remote get-url origin | sed -E 's/\.git$//').git\", from: \"$VERSION\")"
