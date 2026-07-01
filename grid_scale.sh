#!/usr/bin/env bash
# Measure attached agent-pane CPU at two grid sizes to expose grid-size scaling.
# Usage: SRC=<binary> ./grid_scale.sh <label>
set -u
LABEL="${1:?label}"
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

echo "### $LABEL"
"$H" start >/dev/null
"$H" panes 30 >/dev/null
"$H" agents 30 >/dev/null
echo "  detached agents:"; "$H" cpu 12

for size in "190 47" "250 64"; do
  set -- $size
  "$H" attach "$1" "$2" >/dev/null
  sleep 7   # let the post-attach full-render burst pass
  echo "  attached ${1}x${2}:"; "$H" cpu 12
  "$H" detach >/dev/null
done
"$H" stop >/dev/null
echo "[grid] done: $LABEL"
