#!/bin/bash
# Fetches real WebKit at the pinned commit into ./wk and applies the two
# disclosed PoC patches. Run from the repo root. Source is re-fetched fresh
# in every job (it's cheap -- shallow + blob-filtered) because only
# WebKitBuild/ itself is checkpointed between jobs, never the source tree.
set -eu
set -o pipefail

: "${PINNED_COMMIT:?PINNED_COMMIT env var must be set}"

git clone --filter=blob:none https://github.com/WebKit/WebKit.git wk
cd wk
git fetch --depth 1 origin "$PINNED_COMMIT"
git checkout "$PINNED_COMMIT"
git log -1 --format="Checked out %H (%cI): %s"

git apply --check ../patches/0001-sender-instrumentation-alert-frame-spoof.patch
git apply --check ../patches/0002-test-addition-frame-spoof.patch
git apply ../patches/0001-sender-instrumentation-alert-frame-spoof.patch
git apply ../patches/0002-test-addition-frame-spoof.patch
echo "Both patches applied cleanly."
git diff --stat
