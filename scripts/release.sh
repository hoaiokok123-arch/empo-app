#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/Empo"
PROJECT_YML="$PROJECT_DIR/project.yml"
IPA_DIR="$REPO_ROOT/build/ipa"
ALTSTORE_SOURCE="$REPO_ROOT/altstore-source.json"

usage() {
    echo "usage: $0 <bump>"
    echo "  bump   major | minor | patch     bump latest tag's segment"
    echo "         <semver>                  explicit version (e.g. 0.1.0)"
    exit 1
}

[[ $# -ne 1 ]] && usage
BUMP_OR_VERSION="$1"

# Resolve the new version. Accepts an explicit semver (`0.1.0`) for
# rare jumps that don't follow the bump-the-last-tag pattern, or one
# of `major` / `minor` / `patch` to derive it from the latest git
# tag matching `v*.*.*`. Falls back to `0.1.0` when no prior tag
# exists so the first release-cut works without a manual seed.
case "$BUMP_OR_VERSION" in
    major | minor | patch)
        LATEST_TAG=$(git -C "$REPO_ROOT" tag --list "v*.*.*" --sort=-v:refname | head -n 1)
        if [[ -z "$LATEST_TAG" ]]; then
            echo "    no prior v*.*.* tag found; seeding at 0.1.0"
            VERSION="0.1.0"
        else
            CURRENT="${LATEST_TAG#v}"
            IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
            case "$BUMP_OR_VERSION" in
                major) VERSION="$((MAJOR + 1)).0.0" ;;
                minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
                patch) VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
            esac
            echo "    bumping $BUMP_OR_VERSION: $LATEST_TAG -> v$VERSION"
        fi
        ;;
    *)
        if ! [[ "$BUMP_OR_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "error: argument must be major|minor|patch or a semver"
            echo "       (e.g. 0.1.0), got: $BUMP_OR_VERSION"
            exit 1
        fi
        VERSION="$BUMP_OR_VERSION"
        ;;
esac

echo "==> releasing v$VERSION"

# Refuse to bump onto an existing tag. Re-cutting an already-shipped
# version overwrites the tag + GitHub release in place, which is
# almost never what `release.sh` should be doing automatically. Use
# manual `git tag -fs` + `gh release upload --clobber` for that
# flow.
if git -C "$REPO_ROOT" rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "error: tag v$VERSION already exists; pick a different bump"
    exit 1
fi

# 1. Check clean tree
if ! git -C "$REPO_ROOT" diff --quiet HEAD; then
    echo "error: working tree is dirty - commit or stash changes first"
    exit 1
fi

# 2. Bump MARKETING_VERSION in project.yml
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $VERSION/" "$PROJECT_YML"

# 3. Inject CURRENT_PROJECT_VERSION from commit count
BUILD=$(git -C "$REPO_ROOT" rev-list --count HEAD)
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD/" "$PROJECT_YML"

echo "    version: $VERSION, build: $BUILD"

# 4. Regenerate Xcode project
cd "$PROJECT_DIR"
/opt/homebrew/bin/xcodegen generate --spec project.yml --project . --quiet
cd "$REPO_ROOT"

# 5. Build unsigned .ipa BEFORE we commit; the IPA's size feeds the
# AltStore manifest update in step 7, and we want every release-flow
# artifact to be staged into the same single chore commit so the
# tag points at a tree consistent with the asset that ships.
echo "==> building unsigned ipa"
BUILD_DIR="$PROJECT_DIR/build/Release-iphoneos"
xcodebuild \
    -project "$PROJECT_DIR/Empo.xcodeproj" \
    -target Empo \
    -sdk iphoneos \
    -arch arm64 \
    -configuration Release \
    CODE_SIGNING_ALLOWED=NO \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    build 2>&1 | grep -E "^(Build|error:|warning: |CompileSwift|Ld )" || true

APP_PATH="$BUILD_DIR/Empo.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: build failed - Empo.app not found at $BUILD_DIR"
    exit 1
fi

# 6. Ad-hoc sign with our entitlements file so the Mach-O has an
# entitlements blob embedded. Sideloaders that resign the IPA
# (AltStore, Sideloadly, ESign, Feather) read this blob as their
# template; without it some resigners synthesize an incomplete
# blob and break runtime behaviors. iOS won't trust the ad-hoc
# signature directly, but every sideloader re-signs over it with
# the user's cert before installing.
#
# `--generate-entitlement-der` writes the modern DER-encoded
# entitlements format alongside the plist form. Required by
# iOS 15+ for some entitlement keys to be honored, and makes
# the signature easier for naive resigners to round-trip
# without losing data.
#
# Don't pass `--options=runtime`: hardened runtime is a macOS
# concept (restricts JIT/dyld/debugger), and setting it on an
# iOS binary makes dyld refuse to load the Mach-O at app
# launch, producing a black screen on startup.
echo "==> ad-hoc signing with entitlements"
codesign --force --sign - \
    --generate-entitlement-der \
    --entitlements "$PROJECT_DIR/Empo.entitlements" \
    "$APP_PATH"

mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_PATH" "$IPA_DIR/Payload/Empo.app"
IPA_NAME="Empo-${VERSION}-unsigned.ipa"
(cd "$IPA_DIR" && zip -qr "$IPA_NAME" Payload)
rm -rf "$IPA_DIR/Payload"
IPA_PATH="$IPA_DIR/$IPA_NAME"
IPA_SIZE=$(stat -f%z "$IPA_PATH")
echo "    ipa: $IPA_PATH ($IPA_SIZE bytes)"

# 7. Generate changelog (uses git-cliff if installed, otherwise a
# generic placeholder). Generated before the version-bump commit
# so `--unreleased` covers everything since the previous tag.
CHANGELOG=""
if command -v git-cliff &>/dev/null; then
    CHANGELOG=$(git-cliff --config "$REPO_ROOT/cliff.toml" --unreleased --strip all 2>/dev/null || true)
fi

if [[ -z "$CHANGELOG" ]]; then
    CHANGELOG="See commit history for changes."
fi

# 8. Update altstore-source.json with the freshly-built IPA's
# size + download URL. AltStore validates that the size in the
# manifest exactly matches the downloaded asset on install; a
# stale entry breaks updates for every AltStore-source-subscribed
# user.
echo "==> updating altstore-source.json"
RELEASE_DATE=$(date -u +"%Y-%m-%d")
DOWNLOAD_URL="https://github.com/mateo-m/empo-app/releases/download/v$VERSION/$IPA_NAME"
bun "$REPO_ROOT/scripts/update-altstore-source.ts" \
    --version "$VERSION" \
    --build "$BUILD" \
    --size "$IPA_SIZE" \
    --date "$RELEASE_DATE" \
    --download-url "$DOWNLOAD_URL" \
    --description "$CHANGELOG"

# 9. Commit + tag (signed). Single commit covers the version
# bump, regenerated xcodeproj, and altstore-source.json update so
# the tag points at a tree consistent with the published IPA.
git -C "$REPO_ROOT" add "$PROJECT_YML" \
    "ios/Empo/Empo.xcodeproj/project.pbxproj" \
    "$ALTSTORE_SOURCE"
git -C "$REPO_ROOT" commit -S -m "chore: bump version to $VERSION (build $BUILD)"
git -C "$REPO_ROOT" tag -s "v$VERSION" -m "v$VERSION"

# 10. Push
echo "==> pushing to origin"
git -C "$REPO_ROOT" push origin main
git -C "$REPO_ROOT" push origin "v$VERSION"

# 11. Create GitHub release
echo "==> creating github release"
gh release create "v$VERSION" \
    --title "v$VERSION" \
    --notes "## What's changed

$CHANGELOG

---
> Unsigned build - resign with [SideStore](https://sidestore.io), AltStore, or Sideloadly before installing." \
    "$IPA_PATH"

echo "==> done - v$VERSION released"
