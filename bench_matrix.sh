#!/usr/bin/env bash
# Run the idle-CPU matrix for one binary and emit clean CPU% + strace -f -c
# syscall summaries. Usage: SRC=<binary> ./bench_matrix.sh <label> <outdir>
set -u
LABEL="${1:?label}"
OUT="${2:?outdir}"
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
PIDFILE=/tmp/herdr-test/herdr.pid
# NOTE: results must live OUTSIDE /tmp/herdr-test — `harness.sh start` rm -rf's it.
mkdir -p "$OUT"

strace_window() {
  local name="$1" secs="${2:-15}"
  local pid; pid=$(cat "$PIDFILE")
  echo "[matrix] strace $name ($secs s) on pid=$pid"
  # ptrace_scope=1 blocks attaching to a sibling, so strace as root.
  sudo timeout -s INT "$secs" strace -f -c -p "$pid" 2>"$OUT/strace-$name.txt" || true
}

echo "### $LABEL" | tee "$OUT/cpu.txt"

"$H" start
"$H" panes 30
sleep 10   # let freshly-spawned zsh panes finish their rc startup and go idle

echo "-- zsh detached --" | tee -a "$OUT/cpu.txt"
"$H" cpu 15 | tee -a "$OUT/cpu.txt"
strace_window "zsh-detached" 15

"$H" agents 30 | tee -a "$OUT/cpu.txt"

echo "-- agents detached --" | tee -a "$OUT/cpu.txt"
"$H" cpu 15 | tee -a "$OUT/cpu.txt"
strace_window "agents-detached" 15

"$H" attach 190 47
sleep 6   # let the post-attach full-render burst pass
echo "-- agents attached 190x47 --" | tee -a "$OUT/cpu.txt"
"$H" cpu 15 | tee -a "$OUT/cpu.txt"
strace_window "agents-attached" 15

"$H" stop
echo "[matrix] done: $LABEL"
