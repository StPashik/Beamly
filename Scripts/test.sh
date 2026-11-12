#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/beamly-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/beamly-spm-cache"

# Tests use the FFmpeg and FFprobe inside this app. Prefer the local build so a
# system FFmpeg cannot silently change the expected media behavior.
if [[ -z "${BEAMLY_TEST_APP_BUNDLE:-}" && -d "$PWD/build/Beamly.app" ]]; then
    export BEAMLY_TEST_APP_BUNDLE="$PWD/build/Beamly.app"
fi
if [[ -n "${BEAMLY_TEST_APP_BUNDLE:-}" && ! -d "$BEAMLY_TEST_APP_BUNDLE" ]]; then
    printf 'BEAMLY_TEST_APP_BUNDLE does not name an application bundle: %s\n' "$BEAMLY_TEST_APP_BUNDLE" >&2
    exit 1
fi
if [[ -z "${BEAMLY_TEST_APP_BUNDLE:-}" ]]; then
    printf 'warning: build/Beamly.app was not found; tests will use a system FFmpeg.\n' >&2
    printf 'warning: run Scripts/build.sh first to test with the bundled FFmpeg and FFprobe.\n' >&2
fi

swift test --disable-sandbox --cache-path .build/cache
