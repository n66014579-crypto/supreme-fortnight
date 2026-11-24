#!/bin/bash
# scripts/check_core_complete.sh <workdir>
#
# Replaces the earlier diagnose_webprocessplugin.sh, which chased a header-
# search-path theory for the recurring WebProcessPlugIn JavaScriptCore
# error. A real run proved that theory wrong: this script's own
# file-existence check (the one part of that earlier diagnostic that
# worked correctly) showed WebKitBuild/Debug/JavaScriptCore.framework and
# WebKit.framework were COMPLETELY MISSING after restoring a checkpoint --
# not present-but-missing-a-header. No framework-search-path flag of any
# kind can fix a framework that was never there to begin with.
#
# v2 (2026-11-23): now also checks each framework's own MAIN BINARY
# directly (the same definition of "complete" that scripts/verify_and_repair.sh
# uses), not just a couple of representative header files, and writes
# core_complete=true/false to $GITHUB_OUTPUT. This lets poc.yml SKIP an
# expensive build step entirely once the core is already done, instead of
# every core-build phase (and build-tests-and-run's own catch-up step)
# unconditionally spending its whole watchdog budget regardless of whether
# there's any real work left -- the concrete fix for "this takes too long":
# phases that aren't needed any more should finish in seconds, not hours,
# rather than the phase COUNT itself being a fixed guess.
#
# This is a fast (no compiling), pure information step. Always exits 0:
# must never fail the job on its own.
set -u

workdir="$1"

cd "$workdir" || exit 0
out_log="../core-completeness-check.log"

jsc_bin="WebKitBuild/Debug/JavaScriptCore.framework/Versions/A/JavaScriptCore"
wk_bin="WebKitBuild/Debug/WebKit.framework/Versions/A/WebKit"

{
  echo "=== Core framework completeness check: $(date -u +%FT%TZ) ==="
  for f in \
    "WebKitBuild/Debug/JavaScriptCore.framework/PrivateHeaders/JSExportMacros.h" \
    "WebKitBuild/Debug/JavaScriptCore.framework/Versions/A/PrivateHeaders/JSExportMacros.h" \
    "WebKitBuild/Debug/WebKit.framework/PrivateHeaders/WKNativeEvent.h" \
    "WebKitBuild/Debug/WebKit.framework/Versions/A/PrivateHeaders/WKNativeEvent.h" \
    "$jsc_bin" \
    "$wk_bin"; do
    if [ -e "$f" ]; then
      echo "FOUND:   $f"
    else
      echo "MISSING: $f"
    fi
  done
  echo
  echo "--- JavaScriptCore.framework layout (top 2 levels) ---"
  find WebKitBuild/Debug/JavaScriptCore.framework -maxdepth 2 2>&1 || echo "(JavaScriptCore.framework not found under WebKitBuild/Debug at all)"
  echo
  echo "--- WebKit.framework layout (top 2 levels) ---"
  find WebKitBuild/Debug/WebKit.framework -maxdepth 2 2>&1 || echo "(WebKit.framework not found under WebKitBuild/Debug at all)"
  echo

  # Authoritative definition of "complete": each framework's own main
  # binary exists -- the same thing verify_and_repair.sh checks, and the
  # actual thing TestWebKitAPI needs to link against. Header presence
  # above is informational only now (kept because it's been useful for
  # spotting partial/weird states in past rounds).
  if [ -e "$jsc_bin" ]; then jsc_complete=1; else jsc_complete=0; fi
  if [ -e "$wk_bin" ]; then wk_complete=1; else wk_complete=0; fi

  if [ "$jsc_complete" = "1" ] && [ "$wk_complete" = "1" ]; then
    core_complete=true
    echo "VERDICT: core looks complete -- the next build step should be a fast, near-instant no-op (and poc.yml will skip it outright)."
  else
    core_complete=false
    echo "VERDICT: core is INCOMPLETE -- the next build step will have real, possibly lengthy, work to finish."
  fi
} > "$out_log" 2>&1

cat "$out_log"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "core_complete=$core_complete" >> "$GITHUB_OUTPUT"
fi

exit 0
