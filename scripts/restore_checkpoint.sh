#!/bin/bash
# scripts/restore_checkpoint.sh <tarball> [deadline_minutes=40]
# Run from the repo root. Extracts <tarball> (downloaded by
# actions/download-artifact into the repo root -- it contains a top-level
# WebKitBuild/ directory, see checkpoint.sh) into wk/, then touches every
# restored file's mtime to "now" -- strictly after this job's fresh source
# checkout in fetch_webkit.sh -- so Xcode's incremental build sees restored
# outputs as newer than the source they came from, rather than deciding
# from checkout-time mtime ordering alone that everything needs relinking.
set -eu
set -o pipefail

tarball="$1"
deadline_minutes="${2:-40}"

mkdir -p wk
echo "Checkpoint extraction started: $(date -u +%FT%TZ)"
bash scripts/run_with_deadline.sh "$deadline_minutes" -- tar -xzf "$tarball" -C wk
rm -f "$tarball"
echo "Checkpoint extraction finished: $(date -u +%FT%TZ)"
du -sh wk/WebKitBuild 2>/dev/null || true

find wk/WebKitBuild -exec touch {} + 2>/dev/null || true
echo "mtime touch-forward done: $(date -u +%FT%TZ)"
