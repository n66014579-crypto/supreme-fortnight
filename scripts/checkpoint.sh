#!/bin/bash
# scripts/checkpoint.sh <tarball_name>
# Run from the repo root. Tars the WHOLE wk/WebKitBuild directory (not just
# wk/WebKitBuild/Debug) into <tarball_name> at the repo root, ready for
# actions/upload-artifact.
#
# This matters: confirmed directly from Tools/Scripts/webkitdirs.pm
# (determineBaseProductDir / the "$baseProductDir/XCBuildData/..." glob)
# that Xcode's own incremental-build state database, XCBuildData/, lives at
# WebKitBuild/XCBuildData -- a SIBLING of WebKitBuild/Debug, not inside it
# -- and the sibling frameinfo-spoofing engagement's own notes independently
# describe compiled .o files living under WebKitBuild/*.build/, also
# siblings of Debug. Checkpointing only WebKitBuild/Debug (an earlier draft
# of this script did exactly that, copied from the single/two-job versions
# of this PoC) would silently discard the one thing a multi-phase chain
# exists to preserve -- the expensive, hours-long compiled-object and
# build-plan state -- leaving every phase to effectively start over.
set -eu

tarball_name="$1"

if [ -d wk/WebKitBuild ]; then
  du -sh wk/WebKitBuild || true
  tar -czf "$tarball_name" -C wk WebKitBuild
  ls -lh "$tarball_name"
else
  echo "::warning::wk/WebKitBuild does not exist -- nothing to checkpoint."
fi
