#!/usr/bin/env bash
# Isolated herdr test harness. SAFETY-HARDENED.
#
# Background: the user's LIVE server may run from target/release/herdr (after a
# `herdr server live-handoff --import-exe .../target/release/herdr`). A broad
# `pkill -f "<that-path> server"` would kill the real server and SIGHUP every
# pane's shell. To make that IMPOSSIBLE, this harness:
#   * runs a SEPARATE binary copy named `herdr-bench` (live server is `herdr
#     server`, so name-based matches can never hit it),
#   * kills ONLY its own tracked PID (no path/pattern pkill against a shared path),
#   * uses a private XDG_CONFIG_HOME/XDG_STATE_HOME AND a private socket path.
set -u

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # self-locate; no hardcoded checkout path
SRC="${SRC:-$PROJ/herdr/target/release/herdr}"
ROOT=/tmp/herdr-test
BIN="$ROOT/herdr-bench"                       # isolated, uniquely-named copy
export XDG_CONFIG_HOME="$ROOT/xdg-config"
export XDG_STATE_HOME="$ROOT/xdg-state"
export HERDR_DISABLE_SOUND=1
export HERDR_SOCKET_PATH="$ROOT/herdr-bench.sock"
unset HERDR_ENV HERDR_CONFIG_PATH HERDR_SESSION

CFGDIR="$XDG_CONFIG_HOME/herdr"
LOG="$ROOT/server.log"
PIDFILE="$ROOT/herdr.pid"
ATTACHPIDFILE="$ROOT/attach.pid"
FAKEBIN="$ROOT/fakebin"
SCREEN="$PROJ/claude-idle-screen.txt"
ATTACH_PY="$PROJ/attach.py"

# Pane cwd pool. PANE_MODE=synth (default): generate independent throwaway git repos
# (portable — no dependency on any machine's personal project layout, and each pane
# gets its OWN repo_root/.git so the periodic git-status refresh isn't deduped away
# across panes the way subdirectories of one repo would be).
# PANE_MODE=real: your own project directories, one per line, in $REAL_CWDS_FILE
# (gitignored — never commit real project paths; only meaningful on the machine that
# has that file and those directories).
PANE_MODE="${PANE_MODE:-synth}"
REAL_CWDS_FILE="$PROJ/real-cwds.txt"

# Create (if missing) 16 independent git repos under $ROOT and print their paths,
# one per line.
_synth_repo_pool() {
  local dir
  for i in $(seq 1 16); do
    dir="$ROOT/cwd-repos/$i"
    if [ ! -d "$dir/.git" ]; then
      mkdir -p "$dir"
      git -C "$dir" init -q
      git -C "$dir" -c user.email=bench@local -c user.name=bench commit -q --allow-empty -m init
    fi
    echo "$dir"
  done
}

# PANE_MODE=open: real popular open-source repos (git history, remotes, branches —
# closer to an actual dev session than synth's empty repos). Cloned once into a cache
# OUTSIDE $ROOT so `start()`'s `rm -rf "$ROOT"` doesn't force a re-clone every run;
# each extra branch is a separate `git worktree` (its own repo_root, same object store).
OPEN_CACHE="$PROJ/.harness-cache/open-repos"
OPEN_REPOS=(
  "funcy|https://github.com/Suor/funcy.git|master typing test-py3.12"
  "django-cacheops|https://github.com/Suor/django-cacheops.git|master 3.x 2.x"
  "battle-brothers-mods|https://github.com/Suor/battle-brothers-mods.git|master ap-delayed-melee-kill autopilot-verbose-double-wrap"
  "battle-brothers-stdlib|https://github.com/Suor/battle-brothers-stdlib.git|master"
  "battle-brothers-rosetta|https://github.com/Suor/battle-brothers-rosetta.git|master"
  "sublime-reform|https://github.com/Suor/sublime-reform.git|master"
  "dot-agent|https://github.com/Suor/dot-agent.git|master"
)

_open_repo_pool() {
  mkdir -p "$OPEN_CACHE"
  local spec name url branches b dir repo_dir first
  for spec in "${OPEN_REPOS[@]}"; do
    IFS='|' read -r name url branches <<<"$spec"
    repo_dir="$OPEN_CACHE/$name"
    [ -d "$repo_dir/.git" ] || git clone -q "$url" "$repo_dir" >/dev/null 2>&1
    first=1
    for b in $branches; do
      if [ "$first" = 1 ]; then
        git -C "$repo_dir" checkout -q "$b" >/dev/null 2>&1
        echo "$repo_dir"
        first=0
      else
        dir="$OPEN_CACHE/$name@$b"
        [ -d "$dir" ] || git -C "$repo_dir" worktree add -q "$dir" "$b" >/dev/null 2>&1
        [ -d "$dir" ] && echo "$dir"
      fi
    done
  done
  # the herdr source submodule bundled with this harness — one more real repo, no clone needed.
  [ -e "$PROJ/herdr/.git" ] && echo "$PROJ/herdr"
}

# Refuse to touch anything if SRC is the path a live server runs from AND we were
# (mis)configured to run that path directly. We never run SRC directly — we copy
# it to BIN — but assert the invariant loudly just in case.
_assert_isolated() {
  case "$BIN" in
    */herdr-bench) : ;;
    *) echo "[harness] REFUSING: BIN must be the herdr-bench copy, got: $BIN" >&2; exit 1 ;;
  esac
}

# The real bench client process: comm is exactly `herdr-bench` (NOT python3, the
# attach.py wrapper) AND its cmdline contains "client" (NOT "server").
_client_pid() {
  local p
  for p in $(pgrep -x herdr-bench 2>/dev/null); do
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "herdr-bench client"; then
      echo "$p"; return 0
    fi
  done
  return 1
}

start() {
  _assert_isolated
  stop 2>/dev/null
  rm -rf "$ROOT"; mkdir -p "$CFGDIR"
  if [ ! -x "$SRC" ]; then echo "[harness] SRC not found/executable: $SRC" >&2; exit 1; fi
  cp "$SRC" "$BIN"                              # fresh copy of the just-built binary
  printf 'onboarding = false\n' > "$CFGDIR/config.toml"
  echo "[harness] SRC=$SRC"
  echo "[harness] BIN=$BIN  SOCKET=$HERDR_SOCKET_PATH"
  # Optional extra env for the server (e.g. SRV_ENV="HERDR_RENDER_PROF=1 HERDR_LOG=herdr=info").
  env ${SRV_ENV:-HERDR_LOG=herdr=warn} nohup "$BIN" server > "$LOG" 2>&1 &
  local pid=$!
  sleep 3
  # Trust the PID we spawned; do NOT pgrep by path (avoids any shared-path match).
  echo "$pid" > "$PIDFILE"
  echo "[harness] server pid=$pid"
}

panes() {
  _assert_isolated
  local n="${1:-40}"
  local CWDS=()
  case "$PANE_MODE" in
    real)
      if [ ! -f "$REAL_CWDS_FILE" ]; then
        echo "[harness] PANE_MODE=real needs $REAL_CWDS_FILE (one directory per line)" >&2
        exit 1
      fi
      while IFS= read -r d; do [ -n "$d" ] && CWDS+=("$d"); done < "$REAL_CWDS_FILE"
      ;;
    open) while IFS= read -r d; do CWDS+=("$d"); done < <(_open_repo_pool) ;;
    *)    while IFS= read -r d; do CWDS+=("$d"); done < <(_synth_repo_pool) ;;
  esac
  echo "[harness] creating workspace + $n idle panes across ${#CWDS[@]} cwds (mode=$PANE_MODE)"
  "$BIN" workspace create --cwd "$HOME" --no-focus >/dev/null 2>&1
  for i in $(seq 1 "$n"); do
    local cwd="${CWDS[$(( (i-1) % ${#CWDS[@]} ))]}"
    [ -d "$cwd" ] || cwd="$HOME"
    "$BIN" tab create --cwd "$cwd" --no-focus >/dev/null 2>&1
  done
  sleep 3
  local np; np=$("$BIN" pane list 2>/dev/null | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["panes"]))' 2>/dev/null)
  echo "[harness] panes now: $np"
}

# Turn the first <count> panes into IDLE agent panes: run a process literally
# named `claude` (a renamed `cat` that blocks on the pty) so the process-probe
# path identifies the agent, and print a realistic claude idle screen so
# detect_agent runs its full text path. This reproduces the live server's
# 4 idle-claude panes. Usage: agents [count]
agents() {
  _assert_isolated
  local count="${1:-4}"
  mkdir -p "$FAKEBIN"
  # A real binary named `claude` → /proc comm == "claude" → identify_agent hits.
  cp /usr/bin/cat "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"
  [ -f "$SCREEN" ] || { echo "[harness] missing $SCREEN" >&2; return 1; }
  local ids; ids=$("$BIN" pane list 2>/dev/null | python3 -c '
import sys,json
print(" ".join(p["pane_id"] for p in json.load(sys.stdin)["result"]["panes"]))')
  local i=0
  for id in $ids; do
    [ "$i" -ge "$count" ] && break
    # clear, print the idle screen, then exec the blocking `claude` (replaces shell).
    "$BIN" pane run "$id" "clear; cat '$SCREEN'; exec '$FAKEBIN/claude'" >/dev/null 2>&1
    i=$((i+1))
  done
  sleep 6   # let the detection loop probe the process + settle on the agent
  echo "[harness] launched fake claude in $i panes"
  agentcount
}

# Report how many panes herdr currently sees an agent in.
agentcount() {
  "$BIN" pane list 2>/dev/null | python3 -c '
import sys,json
from collections import Counter
panes=json.load(sys.stdin)["result"]["panes"]
c=Counter(p.get("agent") for p in panes)
print("[harness] panes:", len(panes), " agents:", {k:v for k,v in c.items() if k})'
}

# Attach a headless client under a fixed-size PTY. Usage: attach [cols] [rows]
attach() {
  _assert_isolated
  local cols="${1:-250}" rows="${2:-64}"
  [ -f "$ATTACH_PY" ] || { echo "[harness] missing $ATTACH_PY" >&2; return 1; }
  detach 2>/dev/null
  nohup python3 "$ATTACH_PY" "$cols" "$rows" "$BIN" client > "$ROOT/attach.log" 2>&1 &
  echo "$!" > "$ATTACHPIDFILE"
  sleep 5
  local cpid; cpid=$(_client_pid)
  echo "[harness] attach.py pid=$(cat "$ATTACHPIDFILE")  client pid=${cpid:-?}  size=${cols}x${rows}"
}

# Detach: kill the attach.py wrapper (which SIGTERMs its client child).
detach() {
  if [ -f "$ATTACHPIDFILE" ]; then
    local p; p=$(cat "$ATTACHPIDFILE")
    [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -f "$ATTACHPIDFILE"
  fi
  # Belt-and-suspenders: kill any stray bench client (unique name, never the live server).
  pkill -f "herdr-bench client" 2>/dev/null
  sleep 1
}

# Paste captured agent-screen text into the first M panes so detect_agent runs
# its full path (to_lowercase etc.). Usage: agentpanes <file> [count]
agentpanes() {
  _assert_isolated
  local file="${1:?need a text file with a claude-idle screen}"
  local count="${2:-6}"
  local ids; ids=$("$BIN" pane list 2>/dev/null | python3 -c '
import sys,json
ids=[p["pane_id"] for p in json.load(sys.stdin)["result"]["panes"]]
print(" ".join(ids))')
  local i=0
  for id in $ids; do
    [ "$i" -ge "$count" ] && break
    "$BIN" pane paste --pane "$id" --text "$(cat "$file")" >/dev/null 2>&1 \
      || "$BIN" send --pane "$id" "$(cat "$file")" >/dev/null 2>&1
    i=$((i+1))
  done
  echo "[harness] pasted agent screen into $i panes"
}

# Measure CPU% of the bench server (and the attached client, if any) over <secs>.
# Reports server, client, and combined so we can see total power draw.
cpu() {
  local pid; pid=$(cat "$PIDFILE" 2>/dev/null)
  local secs="${1:-15}"
  local cpid; cpid=$(_client_pid)
  local hz; hz=$(getconf CLK_TCK)
  _ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo NA; }
  local sp1 cl1 sp2 cl2 t1 t2
  sp1=$(_ticks "$pid"); cl1=$(_ticks "${cpid:-0}"); t1=$(date +%s.%N)
  sleep "$secs"
  sp2=$(_ticks "$pid"); cl2=$(_ticks "${cpid:-0}"); t2=$(date +%s.%N)
  python3 -c "
hz=$hz; dt=$t2-$t1
sp=($sp2-$sp1)/hz/dt*100 if '$sp1'!='NA' and '$sp2'!='NA' else float('nan')
cl=($cl2-$cl1)/hz/dt*100 if '$cl1'!='NA' and '$cl2'!='NA' else 0.0
client='${cpid:-none}'
print(f'server={sp:5.2f}%  client={cl:5.2f}%  total={sp+cl:5.2f}%  over={dt:.1f}s  spid=$pid cpid={client}')
"
}

pid() { cat "$PIDFILE" 2>/dev/null; }

stop() {
  detach 2>/dev/null
  # Kill ONLY our tracked PID. No path-based pkill (the live server could share
  # the path). The unique `herdr-bench` name makes even an accidental match safe,
  # but we still avoid pattern-kills entirely.
  if [ -f "$PIDFILE" ]; then
    local p; p=$(cat "$PIDFILE")
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      # Confirm it's really our bench server before killing.
      if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "herdr-bench server"; then
        kill "$p" 2>/dev/null
      fi
    fi
    rm -f "$PIDFILE"
  fi
  sleep 1
}

"$@"
