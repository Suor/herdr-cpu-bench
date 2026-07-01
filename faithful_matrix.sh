#!/usr/bin/env bash
# Faithful reported scenario: 44 panes (43 + root), 4 idle agents — the rest idle
# zsh. CPU% + strace -f -c per scenario. Usage: SRC=<binary> ./faithful_matrix.sh <label> <outdir>
set -u
LABEL="${1:?label}"
OUT="${2:?outdir}"   # MUST be outside /tmp/herdr-test (harness start rm -rf's it)
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
PIDFILE=/tmp/herdr-test/herdr.pid
mkdir -p "$OUT"

strace_window() {
  local name="$1" secs="${2:-15}"
  local pid; pid=$(cat "$PIDFILE")
  echo "[matrix] strace $name ($secs s) on pid=$pid"
  sudo timeout -s INT "$secs" strace -f -c -p "$pid" 2>"$OUT/strace-$name.txt" || true
}

echo "### $LABEL"
"$H" start >/dev/null
"$H" panes 43 >/dev/null
"$H" agents 4 | grep -E "agents:"
sleep 8   # settle

echo "-- detached --"; "$H" cpu 15
strace_window "detached" 15

"$H" attach 190 47 >/dev/null; sleep 7
echo "-- attached 190x47 --"; "$H" cpu 15
strace_window "attached-190x47" 15
"$H" detach >/dev/null

"$H" attach 250 64 >/dev/null; sleep 7
echo "-- attached 250x64 --"; "$H" cpu 15
"$H" detach >/dev/null

"$H" stop >/dev/null
echo "[matrix] done: $LABEL"
