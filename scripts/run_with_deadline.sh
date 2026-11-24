#!/bin/bash
# scripts/run_with_deadline.sh <minutes> -- <command...>
#
# Runs <command...> in its own process group. If it is still running after
# <minutes>, sends SIGTERM to the whole group, waits up to 10s, then
# escalates to SIGKILL. Unlike watchdog_build.sh, hitting the deadline here
# IS treated as a real problem: it means a step that should always be fast
# (checkpoint restore, clearing stale build products) stalled, so this
# fails loudly (::error:: + exit 1) instead of continuing silently and
# burning the rest of the job's time budget with nothing to show for it --
# this is the fix for the exact "margin gap" failure mode found in the
# sibling frameinfo-spoofing engagement (restore-heavy jobs ran out of time
# with zero artifact produced and no indication of why).
set -u

minutes="$1"
shift
if [ "$1" = "--" ]; then shift; fi

set -m
"$@" &
pid=$!
set +m

budget=$(( minutes * 60 ))
elapsed=0
poll=5

while kill -0 "$pid" 2>/dev/null; do
  if [ "$elapsed" -ge "$budget" ]; then
    echo "::error::'$*' did not finish within ${minutes} minute(s) -- killing it"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 10
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exit 1
  fi
  sleep "$poll"
  elapsed=$((elapsed + poll))
done

wait "$pid"
exit $?
