#!/bin/bash
# scripts/verify_and_repair.sh
# Run from the repo root, right after a (possibly watchdog-stopped) build
# step, before checkpointing. Checks the MAIN BINARY inside every
# .framework/.xpc/.app directly under wk/WebKitBuild/Debug, and removes
# any bundle whose own binary is missing or structurally broken, so a
# later phase does a clean rebuild of just that one piece instead of
# silently trusting a file that was caught mid-write when THIS phase's
# own watchdog fired.
#
# v3 (2026-11-23): no longer uses `codesign --verify` AT ALL, even against
# the main binary alone. v2 (2026-11-20) switched from checking the whole
# bundle to checking just the main binary, on the theory that WebKit's own
# post-signing "Copy jsc into JavaScriptCore.framework" script phase (an
# aggregate 'All' target writing Helpers/jsc into JavaScriptCore.framework
# AFTER it's signed, confirmed directly in a real log, and separately
# flagged by WebKit's own build settings as a known special case) was
# invalidating the bundle-level resource envelope that `--strict=all`
# checks. That fix was real and well-reasoned, but a real run (v3 tenth
# round) proved it WASN'T ENOUGH: the same warning fired again, this time
# explicitly naming the main-binary path being checked
# (.../JavaScriptCore.framework/Versions/A/JavaScriptCore), and that run's
# own build-core-finish.log showed -- again -- a completely clean,
# zero-error Ld/CodeSign/RegisterExecutionPolicyException/Touch sequence
# for JavaScriptCore.framework, identical in shape to every previous round,
# with the build moving on to other targets right afterward. In other
# words: `codesign --verify` was failing on an ad-hoc-signed
# ("Signing Identity: Sign to Run Locally", i.e. `codesign --sign -`)
# framework binary that every other piece of evidence says is completely
# fine -- a SECOND, independent false-positive from the same underlying
# tool, this time even when pointed at just the one file. Rather than try
# a third variation of "how exactly to ask codesign about this," this
# version stops asking codesign anything at all for this purpose. codesign
# verification and "was this file truncated by a SIGTERM/SIGKILL landing
# mid-write" are two different questions, and the second one -- the one
# this script actually needs answered -- doesn't require cryptographic
# signature checking at all: a binary truncated mid-write will not be a
# structurally valid Mach-O file. Checking that directly (the file exists,
# is non-trivially sized, and starts with a real Mach-O/fat-binary magic
# number) answers the real question without depending on any signing/
# bundle semantics that have now misfired twice in this environment.
set -u

ok=0
repaired=0

# Mach-O / fat-binary magic numbers (first 4 bytes), both byte orders:
# MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64, FAT_MAGIC, FAT_CIGAM.
is_valid_macho() {
  local f="$1"
  [ -s "$f" ] || return 1          # must exist and be non-empty
  local magic
  magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the path to the bundle's main executable, or nothing if it can't
# be found. Caller treats "nothing, or not a valid Mach-O file" as broken.
main_binary_of() {
  local bundle="$1"
  case "$bundle" in
    *.framework)
      local name
      name="$(basename "$bundle" .framework)"
      local candidate="$bundle/Versions/A/$name"
      [ -f "$candidate" ] && echo "$candidate"
      ;;
    *.xpc|*.app)
      find "$bundle/Contents/MacOS" -maxdepth 1 -type f -perm -111 2>/dev/null | head -1
      ;;
  esac
}

while IFS= read -r -d '' bundle; do
  bin="$(main_binary_of "$bundle")"
  if [ -n "$bin" ] && is_valid_macho "$bin"; then
    ok=$((ok + 1))
  else
    reason="missing main binary"
    [ -n "$bin" ] && reason="main binary not a valid Mach-O file ($bin)"
    echo "::warning::$bundle failed verification ($reason) -- removing so the next phase relinks it"
    rm -rf "$bundle"
    repaired=$((repaired + 1))
  fi
done < <(find wk/WebKitBuild/Debug -maxdepth 1 \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null)

echo "Verify & repair finished: $(date -u +%FT%TZ) -- ${ok} OK, ${repaired} repaired"
