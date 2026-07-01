#!/usr/bin/env bash
# Isolate idle-zsh-only cost (NO agents) at three view states.
# Usage: SRC=<binary> ./zsh_only.sh <label> <npanes>
set -u
LABEL="${1:?label}"; N="${2:-43}"
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
echo "### $LABEL — $N idle zsh, 0 agents"
"$H" start >/dev/null
"$H" panes "$N" >/dev/null
sleep 8
echo "  detached:"; "$H" cpu 12
for size in "190 47" "250 64"; do
  set -- $size
  "$H" attach "$1" "$2" >/dev/null; sleep 7
  echo "  attached ${1}x${2}:"; "$H" cpu 12
  "$H" detach >/dev/null
done
"$H" stop >/dev/null
echo "[zsh] done"
