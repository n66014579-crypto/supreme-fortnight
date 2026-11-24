#!/bin/bash
# scripts/clear_stale_products.sh [deadline_minutes=10]
# Run from the repo root, after restore_checkpoint.sh, before resuming the
# build. Unconditionally removes every already-linked/signed
# .framework/.xpc/.app bundle and loose executable sitting directly under
# wk/WebKitBuild/Debug -- regardless of whether it looks fine -- while
# leaving the expensive, already-compiled .o files under
# wk/WebKitBuild/*.build/ completely untouched.
#
# Why: a resumed build can choose to re-link/re-sign an already-fine
# restored bundle, and when THAT redo gets interrupted or behaves
# differently on a restored-onto-a-different-VM checkpoint, the result can
# come out corrupted in a way that verify_and_repair.sh (which only catches
# damage from the PREVIOUS phase's own watchdog stop) can't see coming,
# because the file was fine going in. Removing the bundle gives the
# resumed build nothing to "redo" at the link/codesign layer -- only
# compilation (the genuinely expensive, hours-long part) is preserved;
# relinking everything from already-compiled objects is real but bounded
# work (minutes, not hours). This is the fix for a real, reproduced-twice
# CodeSign corruption failure in the sibling frameinfo-spoofing engagement
# that a verify-only pass did not catch.
set -eu

deadline_minutes="${1:-10}"
echo "Clearing stale final build products: $(date -u +%FT%TZ)"
bash scripts/run_with_deadline.sh "$deadline_minutes" -- find wk/WebKitBuild/Debug -maxdepth 1 -type d \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) -print -exec rm -rf {} +
bash scripts/run_with_deadline.sh "$deadline_minutes" -- find wk/WebKitBuild/Debug -maxdepth 1 -type f -perm -u+x -print -delete
echo "Stale-product clear finished: $(date -u +%FT%TZ)"
