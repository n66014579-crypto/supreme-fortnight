#!/bin/bash
# scripts/watchdog_build.sh <minutes> <workdir> <log_file> -- <command...>
#
# Runs <command...> (cwd=<workdir>) in its own process group, tee'd to
# <log_file> (relative to <workdir>). If it has not exited naturally after
# <minutes>, sends SIGTERM to the whole process group (not just the
# top-level PID, so xcodebuild's own child compile/link/codesign processes
# get it too), waits up to 90s for a clean exit, then escalates to SIGKILL
# only if it still hasn't exited. 90s (not the 15s used earlier in the
# sibling frameinfo-spoofing engagement) specifically to give an in-flight
# codesign or link step more room to finish writing rather than being
# caught mid-write -- that mid-write truncation is what caused this exact
# chain's CodeSign corruption failures previously.
#
# Writes build_outcome=completed|watchdog_stopped|failed and
# build_exit_code=<n> to $GITHUB_OUTPUT. A deliberate watchdog stop is a
# ROUTINE, EXPECTED outcome for a multi-hour build that doesn't fit one
# job -- this script exits 0 for both "completed" and "watchdog_stopped".
# It exits 1 (failing the step for real, on purpose) only for "failed"
# (the command exited non-zero on its own, i.e. a genuine compile error) --
# this is the fix for the "masked failures" bug found in the sibling
# engagement, where an earlier version's unconditional exit 0 let a real
# build-command regression go unnoticed for a full round of CI runs.
set -u

minutes="$1"
workdir="$2"
log_file="$3"
shift 3
if [ "$1" = "--" ]; then shift; fi

set -m
( cd "$workdir" && set -o pipefail && "$@" 2>&1 | tee "$log_file" ) &
pid=$!
set +m

echo "Build started: $(date -u +%FT%TZ), watchdog=${minutes}m, workdir=${workdir}"

budget_seconds=$(( minutes * 60 ))
elapsed=0
poll=30
outcome="completed"

while kill -0 "$pid" 2>/dev/null; do
  if [ "$elapsed" -ge "$budget_seconds" ]; then
    echo "::warning::Watchdog budget of ${minutes}m reached -- sending SIGTERM to process group $pid"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    outcome="watchdog_stopped"
    grace=0
    while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 90 ]; do
      sleep 5
      grace=$((grace + 5))
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "::warning::Process did not exit within 90s of SIGTERM -- escalating to SIGKILL"
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    fi
    break
  fi
  sleep "$poll"
  elapsed=$((elapsed + poll))
done

wait "$pid"
build_exit=$?
echo "Build step ended: $(date -u +%FT%TZ), outcome=${outcome}, raw_exit_code=${build_exit}"

if [ "$outcome" = "completed" ] && [ "$build_exit" -ne 0 ]; then
  outcome="failed"
fi

{
  echo "build_outcome=${outcome}"
  echo "build_exit_code=${build_exit}"
} >> "$GITHUB_OUTPUT"

if [ "$outcome" = "failed" ]; then
  exit 1
fi
exit 0
