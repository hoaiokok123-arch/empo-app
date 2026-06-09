#!/usr/bin/env bash
# Fail fast if iphoneos dependency artifacts are missing, too small,
# simulator-contaminated, or obviously broken.
#
# Usage: scripts/verify-device-deps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/ios/Dependencies/build-iphoneos-arm64/lib"
SIM_LIB="$REPO_ROOT/ios/Dependencies/build-iphonesimulator-arm64/lib"
RUBY_SRC="$REPO_ROOT/ios/Dependencies/sources/ruby"

fail() {
    echo "error: $*" >&2
    exit 1
}

require_file_min() {
    local path="$1" min_bytes="$2" label="$3"
    [[ -f "$path" ]] || fail "missing $label ($path)"
    local size
    size=$(stat -f%z "$path")
    [[ "$size" -ge "$min_bytes" ]] || fail "$label too small (${size} bytes; need >= ${min_bytes})"
}

has_platform() {
    local path="$1" platform="$2"
    otool -l "$path" 2>/dev/null | rg "platform ${platform}" | head -1 | grep -q .
}

require_platform_device_only() {
    local path="$1" label="$2"
    if ! has_platform "$path" 2; then
        fail "$label has no device (platform 2) objects"
    fi
    if has_platform "$path" 7; then
        fail "$label contains simulator (platform 7) objects"
    fi
}

require_global_binding() {
    local merged="$1" ver="$2"
    local sym="_mkxp_get_script_binding_${ver}"
    nm "$merged" 2>/dev/null | awk -v sym="$sym" '$3 == sym {found=1} END {exit !found}' \
        || fail "mkxp${ver}-merged.o missing ${sym}"
    local tglobals
    tglobals=$(nm "$merged" | awk '$2 == "T" {print $3}' | sort -u | wc -l | tr -d ' ')
    [[ "$tglobals" -eq 1 ]] || fail "mkxp${ver}-merged.o should expose 1 global T symbol, found ${tglobals}"
}

echo "==> verifying merged mkxp objects"
for ver in 18 19 31; do
    merged="$LIB/mkxp${ver}-merged.o"
    require_file_min "$merged" 1000000 "mkxp${ver}-merged.o"
    require_platform_device_only "$merged" "mkxp${ver}-merged.o"
    require_global_binding "$merged" "$ver"
done

echo "==> verifying Ruby 3.1 archives"
for name in libruby.3.1-static.a libruby.3.1-ext.a; do
    path="$LIB/$name"
    require_file_min "$path" 5000000 "$name"
    require_platform_device_only "$path" "$name"
done

echo "==> verifying OpenSSL static libs"
for name in libcrypto.a libssl.a; do
    path="$LIB/$name"
    min=100000
    [[ "$name" == "libcrypto.a" ]] && min=1000000
    require_file_min "$path" "$min" "$name"
    require_platform_device_only "$path" "$name"
done

echo "==> verifying Ruby 1.8 / 1.9 archives"
for name in libruby18-static.a libruby19-static.a; do
    path="$LIB/$name"
    require_file_min "$path" 1000000 "$name"
    require_platform_device_only "$path" "$name"
done
for name in libruby18-ext.a libruby19-ext.a; do
    path="$LIB/$name"
    # Empty ext archives from silent make failures land at ~96 bytes.
    require_file_min "$path" 100000 "$name"
    require_platform_device_only "$path" "$name"
done

echo "==> checking Ruby generated sources"
if find "$RUBY_SRC" -maxdepth 3 -type f -size 0 \
    \( -name 'lex.c' -o -path '*/jis/props.h' \) -print 2>/dev/null | grep -q .; then
    find "$RUBY_SRC" -maxdepth 3 -type f -size 0 \
        \( -name 'lex.c' -o -path '*/jis/props.h' \) -print >&2
    fail "zero-byte Ruby generated files — rerun scripts/rebuild-device-deps.sh"
fi

if [[ -f "$SIM_LIB/libruby.3.1-ext.a" && -f "$LIB/libruby.3.1-ext.a" ]]; then
    if [[ "$SIM_LIB/libruby.3.1-ext.a" -nt "$LIB/libruby.3.1-ext.a" ]]; then
        fail "simulator libruby.3.1-ext.a is newer than device — rebuild device deps"
    fi
fi

echo "OK: device dependency artifacts look healthy"
