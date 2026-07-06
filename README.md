# herdr-cpu-bench

A safety-hardened harness for measuring [herdr](https://github.com/ogulcancelik/herdr)'s
idle CPU usage — the tool behind the numbers in
[ogulcancelik/herdr#726](https://github.com/ogulcancelik/herdr/issues/726).

It spins up an isolated herdr server, creates a realistic multi-pane session (plain
shells, idle agent panes, an attached client) and reports CPU%. It never touches a
real/live herdr session — see "Safety model" below.

The point of the harness is a fair, reproducible **A/B**: build two herdr binaries and
measure them back-to-back in the same session. The bundled `herdr/` submodule (a fork of
upstream) carries the two branches this repo compares:

- **`master`** — the upstream baseline ("herdr master").
- **`proper-fix`** — the idle-CPU fix ("Suor's fixed version"), plus the changes described
  in [What the fix does](#what-the-fix-does).

## Requirements

- `bash`, `python3`, `git`
- To build herdr itself: `cargo` + [`zig`](https://ziglang.org/) **0.15.x** (herdr vendors
  `libghostty-vt` via a zig build step — its `build.zig.zon` hard-errors on any other
  zig major.minor). If `zig` isn't on `PATH`, pass it explicitly: `ZIG=/path/to/zig ./build.sh ...`.
- Optional: `sudo` + `strace`, for the syscall breakdown in `faithful_matrix.sh` /
  `bench_matrix.sh` (the CPU%-only measurement works without it).

## Get the source

```sh
git clone --recurse-submodules https://github.com/Suor/herdr-cpu-bench.git
cd herdr-cpu-bench
# or, if already cloned without submodules:
git submodule update --init
```

## Quick start

Build the baseline and the fixed binary from the bundled submodule (`build.sh` checks out
the ref, builds it, and drops `bin/herdr-<label>`; `ZIG=` only needed if zig isn't on `PATH`):

```sh
ZIG=/path/to/zig ./build.sh master     master   # baseline  -> bin/herdr-master
ZIG=/path/to/zig ./build.sh proper-fix fixed    # the fix    -> bin/herdr-fixed
```

Then measure each, back-to-back:

```sh
SRC=bin/herdr-master ./harness.sh start
./harness.sh panes 43
./harness.sh agents 4
sleep 8
./harness.sh cpu 15                 # detached
./harness.sh attach 190 47
sleep 7
./harness.sh cpu 15                 # attached
./harness.sh detach
./harness.sh stop
# ...repeat with SRC=bin/herdr-fixed
```

Or run the full scripted scenario in one shot per binary:

```sh
SRC=bin/herdr-master ./bench_matrix.sh master ./results/master   # 30 idle zsh → 30 idle agents → attach (the #726 scenario)
SRC=bin/herdr-fixed  ./bench_matrix.sh fixed  ./results/fixed
```

`faithful_matrix.sh` runs a similar scenario with 43 mixed panes + 4 idle agents at
both 190×47 and 250×64 attach sizes. (`results/` is gitignored.)

Letting an agent (Claude Code, Codex, …) drive this? See [`AGENTS.md`](AGENTS.md) — it
turns "compare herdr master with Suor's fixed version" into the steps above.

## What you should see

A verified run (43 panes, 4 idle "claude" panes, 190×47 attach; averages of 2 `cpu`
samples per cell). **Absolute numbers drift with your machine and ambient load — only
differences measured within one back-to-back session are meaningful.**

| Variant       | Detached total | Attached total | Built from               |
|---------------|---------------:|---------------:|--------------------------|
| `master`      |         2.80%  |         8.53%  | `master` @ `4421c0f`     |
| `proper-fix`  |         0.20%  |         0.43%  | `proper-fix` @ `d03bf74` |

`proper-fix` used about **14× less CPU detached** and about **20× less total CPU attached**
in this run. See [`REPORT.md`](REPORT.md) for the deeper write-up, including non-idle
(chatty/flood) scenarios.

## What the fix does

herdr's idle CPU was dominated by **polling loops that woke on timers even when nothing
changed**. The expensive work (screen extraction, agent detection) is already event-driven
via PTY output; the fix makes the idle paths block until a real event instead of polling:

1. **Event-driven detection** — detection wakes on PTY output (a `Notify`) instead of a
   fixed 300/500 ms tick; idle panes park for seconds. (`src/pane.rs`, `src/pane/terminal.rs`)
2. **Blocking PTY actor** — the actor blocks until a real event instead of `poll()`ing its
   fd every 50 ms. (`src/pty/actor/unix.rs`) — the largest single detached win.
3. **Event-driven client writer** — the attached client's writer blocks on a `Condvar`
   instead of a 5 ms `recv_timeout` busy-poll. (`src/server/client_transport.rs`)
   *Note: upstream v0.7.1 shipped an equivalent fix independently (`27ff4dd`).*
4. **No-op render skip** — a `StateChanged` that changes no rendered output no longer
   forces a full render (e.g. the 1.5 s git-status refresh). (`src/app/api.rs`,
   `src/server/headless.rs`) — the largest attached win.
5. **Animation timer gated on an attached client** — the spinner tick only scans panes
   when a client is attached. (`src/app/runtime.rs`)
6. **Hook-authority refresh gate** — the 800 ms held-signal republish runs only while a
   hook authority actually exists. (`src/pane/terminal.rs`, `src/pane.rs`, `src/app/api.rs`)
7. **Descendant-walk foreground probe** — the agent-detection probe walks the shell's
   descendant tree instead of scanning all of `/proc`. (`src/pane.rs`, `src/platform/linux.rs`)

Plus (on `proper-fix`, see `REPORT.md`): a 250 ms detection debounce under sustained
output, render gating for panes hidden from every client view, and treating an unfocused
host terminal as displaying nothing.

Remaining floor (unchanged upstream design): the client-accept listener is polled every
250 ms, and the server renders "virtually" on PTY output even with no client attached.

## Commands (`harness.sh`)

| Command | Effect |
|---|---|
| `start` | Copy `$SRC` to an isolated `herdr-bench` binary and launch it (private socket + XDG dirs) |
| `panes [N]` | Create N idle panes (default 40) across the cwd pool (`PANE_MODE`, below) |
| `agents [N]` | Turn the first N panes into idle "claude" agent panes (default 4) |
| `agentcount` | Report how many panes herdr currently sees an agent in |
| `attach [cols rows]` | Attach a headless client under a fixed-size PTY (default 250×64) |
| `detach` | Kill the attached client |
| `cpu [secs]` | Report server/client/combined CPU% over the window (default 15s) — the real measurement |
| `stop` | Kill the bench server |

Extra server env: `SRV_ENV="HERDR_RENDER_PROF=1 HERDR_LOG=herdr=info" ./harness.sh start`
logs per-second render counts to the bench server log under `/tmp/herdr-test/`.

## `PANE_MODE` — the pane cwd pool

Idle panes sit in different working directories so herdr's per-pane git-status refresh
does real work (not a fast "not a repo" no-op). Three modes, selected via `PANE_MODE`:

- **`synth`** (default) — generates 16 independent throwaway `git init` repos under the
  harness's scratch dir. Fully offline, fully portable, no dependency on any machine's
  personal project layout.
- **`open`** — clones a handful of small open-source repos (funcy, cacheops, etc.),
  worktreeing several branches of each, plus reuses the bundled `herdr/` submodule.
  Closer to a real dev session (real history, remotes, branches). First run clones
  (~20 MB); cached under `.harness-cache/`, unaffected by `start()`'s cleanup.
- **`real`** — your own project directories, one per line, in a `real-cwds.txt` file next
  to `harness.sh` (gitignored — create your own locally, never commit real project
  paths). Falls back to `$HOME` for any listed dir that doesn't exist.

```sh
PANE_MODE=open SRC=bin/herdr-master ./harness.sh start
```

## Safety model

Designed so it can never touch a real, already-running herdr session, even by accident:

- Runs a **separate binary copy** named `herdr-bench` (a real herdr server process is
  just `herdr`, so name-based process matching can never hit it).
- Kills **only its own tracked PID** — no path- or pattern-based `pkill` against a binary
  path a real server might share.
- Uses a **private `XDG_CONFIG_HOME`/`XDG_STATE_HOME` and socket path**
  (`/tmp/herdr-test/...`), so it never reads or writes a real session's config/state or
  connects to a real session's socket.

If you have a real herdr session running on the same machine, this harness will not
interact with it as long as you always go through `harness.sh` — don't invoke the
`herdr-bench` binary or point a bare `herdr` client at its socket directly.
