# HANDOFF — herdr idle-CPU fix

Pick-up notes for continuing this work (next session / teammate / future me).
Fixes are referred to BY NAME, never by number, on purpose.

## Status update 2026-06-12: `proper-fix` branch (non-idle CPU)

THREE commits on top of `slim-fix` (5 files, +257/−6), full story + numbers in
`REPORT.md`; binary `bin/herdr-proper-fix` + `~/.local/bin` symlink:
1. `cca71f2` detection debounce — ≤1 output-driven detection pass per 250 ms
   per pane (yes-flood 122→97% of a core, chatty attached 25.3→10.7%)
2. `fa863ef` hidden-pane render gating — `visible_to_client` on PaneTerminal,
   synced from `state.view.pane_infos` after every full render; output of
   background-tab/detached panes no longer wakes the render loop (chatty
   detached 7.1→1.7%, attached 10.7→3.3%); grid/detection/sidebar unaffected
3. `26e880f` unfocused host terminal (hidden Guake tab) counts as displaying
   nothing — uses the client's existing focus reporting; e2e: stream stops to
   0 bytes/3s on focus-out, resumes on focus-in; sound alarms unaffected
   (detection is render-independent)
Tests 1968/1968 (new visibility-sync test). `git diff slim-fix..proper-fix`.

SHELVED: `pace-fix` branch (= proper-fix + `a82bd44`) — hidden-pane PTY read
pacing (≤8×8KiB per 100 ms while hidden ≈ 640 KiB/s; hidden yes-flood
92→6.5% via kernel-buffer backpressure). Works and is tested (1969/1969 on
that branch), but Suor rejected it for the deliverable: it couples a hidden
program's execution speed to tab visibility (a warning-heavy build would
slow down on tab switch — "not pretty"). Kept for emergencies (runaway
processes). The PROPER fix for the residual 92% hidden-flood cost is
upstream in libghostty-vt: 38–43% of flood cycles are full-page memset when
recycling scrollback pages (`PageList.grow()` prune path / `Page.reinit`,
~1.6 KiB zeroed per scrolled line at the cap). Issue draft (investigated,
with source attribution + profiles, awaiting Suor's review before posting
to ghostty-org/ghostty): `ghostty-vt-memset-issue.md`.

NOT yet handed off to the live server; live still runs `herdr-slim-probe-fix`.

## Status
Idle CPU rewritten from polling to event-driven, then dead weight removed. The current
tip is the `slim-fix` branch in ./herdr — FOUR semantic commits on top of `master`
(workflow: no more squashing; new logical changes get their own commits):
1. `b9775b9` the event-driven rewrite (incl. the detection-stall fix below; comments
   describe current behavior, the "why we changed" story lives in the commit message)
2. `40b3f93` foreground_job walks shell descendants instead of all of /proc
3. `2b7fec2` /proc stat read without allocation churn (measured: 7.3→4.0 µs/call at
   ~160 calls/s under a chatty-pane workload ≈ 0.05% CPU — kept, it's real)
4. `ca09166` tidy pass, no behavior change (−40 LOC: output_generation moved next to
   detection_wake on PaneTerminal so the ghostty layer is untouched; loops-with-value
   in client_writer_loop; while-let work queue in descendant_pids; folded duplicate
   conditions)
Diff vs master: 10 files, +611/−138. `cargo test --release --bin herdr`: 1967/1967.
The deliverable is the git branches (below) — push `slim-fix` and open a PR. (The
`*.patch` files in this dir are legacy from an earlier workflow; ignore/remove.)

**⚠️ Latent detection-stall bug in monstro/full/clean (fixed in slim-fix and
slim-probe-fix, which the live server now runs).** The event-driven rewrite can stall
agent detection FOREVER:
`should_probe_foreground_job` only time-rechecked an unidentified pane when it had NO
known foreground group. A silent `exec` (foreground replaced with no pgid change and no
repaint — exactly what `harness.sh agents` does; `exec` keeps the shell's pid+pgid)
produces no group change, no output wake, no recheck. Master's 500 ms poll masked it by
densely sampling group transitions. Bench symptom: `agents 4` yields 0–2 identified,
permanently; any repaint (e.g. client attach → resize) unsticks it. THE FIX (in the
rewrite commit): the 30 s unidentified recheck (renamed `PROCESS_RECHECK_UNIDENTIFIED`)
now fires regardless of pgid presence; one master test inverted accordingly
(`stable_unidentified_foreground_group_reprobes_on_cadence`). Worst-case identification
after a silent exec is now ≤30 s; instant on any repaint. With the fix the bench
identifies 4/4 reliably (3/3 runs, ~26 s incl. the stragglers); clean-fix the same hour:
0/4, 2/4, 0/4, 0/4, 0/4.

**Measured on the faithful harness (43 panes, 4 idle claude agents, 190×47 client).
Each pair below was A/B'd back-to-back; absolute numbers drift with ambient machine
load between sessions, so only compare within a pair:**

| Mode      | Baseline (this harness) | monstro-fix | full-fix | Live server before (real) |
|-----------|------------------------:|------------:|---------:|--------------------------:|
| Detached  | 4.3%                    | 0.55%       | **0.35%**| 3.0%                      |
| Attached  | 7.0%                    | 0.80%       | **0.50%**| 7.8%                      |

probe-fix pair (2026-06-11, probe-harness.sh: 44 panes, 4 agents, 3 × `top -d 3`
bursty panes, 190×47 client — reproduces the LIVE residual): clean-fix 3.90% →
**probe-fix 0.70%** server CPU, 4/4 agents identified, 1967/1967 tests. Root cause:
panes with periodic output (gaps >2s: top, log tails) re-open the agent-acquisition
window forever; each probe whose foreground isn't an agent ran `foreground_job` =
stat of EVERY /proc PID. probe-fix walks the shell's descendant tree instead
(/proc/<pid>/task/<tid>/children), full-scan fallback kept. The earlier harness
missed this because restored panes don't re-run their commands (all silent).

slim-fix vs master NON-IDLE pair (2026-06-11, source-built master `0722270`, same
zig toolchain; 44 panes, 4 agents; back-to-back): the concern was that the uncapped
event-driven detection (a pass per PTY-output batch vs master's 300/500 ms tick)
could cost MORE under load. Measured: no regression anywhere. Chatty tier (4 panes
× `date` every 50 ms ≈ 20 lines/s): detached master 27.1% → **slim-fix 9.9%**,
attached 190×47 master 52.8% → **slim-fix 25.3%**. Flood tier (1 pane `timeout 45
yes`, detached): master 127% ≈ slim-fix 122% — both saturate a core; `yes` is
flow-controlled so this bounds CPU, not work. perf under flood: slim-fix spends
37% of cycles in `ghostty_recent_text` (detection_text, uncapped per-batch) vs
master's 7.8% — master instead burns 57% in `process_pty_bytes` and, under chatty,
38% in `recent_text` from its unconditional every-tick extraction of ALL 44 panes.
So the per-batch detection cost is real but is more than paid for by everything
else the rewrite removed. Possible future shave (not a regression): a minimal
inter-pass interval (~100–300 ms coalesce) for detection under sustained output
would cut roughly a third of flood-saturation cycles.

clean-fix vs full-fix pair (noisier session; equal or better everywhere):
detached idle 0.60% → **0.50%**, attached idle 0.80% → **0.75%**, attached active
(4 background panes × 20 lines/s) 0.80% → **0.60%**.

slim-fix vs clean-fix pair (2026-06-11, both at 4/4 identified agents; clean-fix needed
an attach/detach repaint to get there, see the stall bug): detached idle 0.42% →
**0.00%**, attached idle 0.50% → **0.50%**. Idle CPU did not go up; frame delivery
re-verified on slim-fix (verify_delivery.py delta=539, exit 0).

~12× reduction vs baseline. The client still receives frames on change
(verify_delivery.py: delta>0), the stale-hook screen-veto works end-to-end (verified on
both full-fix and clean-fix), 1967 tests pass. Input latency was verified ≤200 ms on
monstro-fix; later branches do not touch the input path.

The live server now runs `herdr-slim-probe-fix` (handoff done 2026-06-11) — it has the
stall fix and the probe fix, but predates the /proc-opt and tidy commits. RECOMMENDED
(low urgency): re-handoff to the final `herdr-slim-fix`. Still pending: that handoff +
upstream PR from `slim-fix`.

## Branches & binaries (A/B the variants)
The herdr git repo (`./herdr`) now has one branch per variant, each off `master` (0.6.8):

| Branch        | Contents                                                        | Diff vs master | Binary (bytes) |
|---------------|----------------------------------------------------------------|---------------:|---------------:|
| `master`      | pristine 0.6.8 (≈ what yay's `/usr/bin/herdr` ships)           | —              | —              |
| `old-fix`     | detection_text memo only                                       | 1 file +33/−2  | 14735536       |
| `triple-fix`  | + detect_agent memo + /proc read                              | 3 files +90/−7 | 14773624       |
| `monstro-fix` | + the four event-driven changes (the full rewrite)            | 10 files +466/−93 | 14770272    |
| `full-fix`    | + the hook-authority refresh gate (off `monstro-fix`)         | 11 files +637/−105 | 14769712   |
| `clean-fix`   | − both detection memos, made dead by the rewrite (off `full-fix`) | 11 files +577/−103 | 14778568 |
| `probe-fix`   | clean-fix + descendant-walk foreground_job                    | 11 files +634/−118 | 14768912   |
| `slim-probe-fix` | rewrite commit + probe commit (frozen; superseded by slim-fix) | 10 files +626/−122 | 14771288 |
| `slim-fix`    | **the deliverable**: rewrite (+stall fix) + probe + /proc opt + tidy, 4 commits | 10 files +611/−138 | 14763168 |
| `proper-fix`  | slim-fix + detection debounce + hidden-pane render gating + focus gating (see REPORT.md) | +5 files +257/−6 vs slim-fix | 14673272 |
| `pace-fix`    | proper-fix + hidden-pane PTY read pacing (SHELVED — couples hidden program speed to visibility) | +1 commit vs proper-fix | — |

Binaries live in `./bin/herdr-<variant>` and are symlinked onto PATH in `~/.local/bin`:
**`herdr-old-fix`, `herdr-triple-fix`, `herdr-monstro-fix`, `herdr-full-fix`,
`herdr-clean-fix`, `herdr-slim-probe-fix`, `herdr-slim-fix`**. The plain `herdr` (`/usr/bin/herdr`, yay-managed)
is deliberately NOT touched. `bin/herdr-master-tmp` (no symlink, throwaway) is a
source-built pristine master kept for non-idle A/Bs. The old-fix and triple-fix binary sizes match the prior
session's `/tmp/herdr-baseline` and `/tmp/herdr-fixed` byte-for-byte, confirming the
reconstruction. `target/release/herdr` currently holds the proper-fix build.
⚠️ The LIVE server currently runs from `bin/herdr-slim-probe-fix` (via the
`~/.local/bin` symlink) — do not overwrite that file in place while it does.

Rebuild any variant: `git checkout <branch> && ZIG=$(pwd)/../zig-x86_64-linux-0.15.2/zig
cargo build --release --bin herdr && cp target/release/herdr ../bin/herdr-<variant>`
(then leave the repo on `slim-fix`). All seven branches build; `slim-fix`, `clean-fix`
and `full-fix` pass 1967/1967 tests, `monstro-fix` and `triple-fix` pass 1966/1966.

## ⚠️ SAFETY — read before running the harness
The user's **live** server currently runs `herdr-slim-probe-fix` (resolves to
`.../herdr-fix/bin/herdr-slim-probe-fix`; PID was 169169 this session — re-check, it
changes on every handoff). Rebuilding `target/release/herdr` does NOT affect it, but do
not `cp` over `bin/herdr-slim-probe-fix` in place while it runs. NEVER `pkill`/`kill` a server by path/pattern
— that can match the live server, SIGHUP every pane shell, and lose in-flight work. Always
`pgrep -af "herdr.*server"` first. `harness.sh` is hardened: separate `herdr-bench` binary
copy, kills only its own PID, private socket + XDG. See `CLAUDE.local.md`.

**⚠️ Raw `herdr`/bench CLI calls go to the LIVE server unless you set the bench env.**
`harness.sh` exports `HERDR_SOCKET_PATH=/tmp/herdr-test/herdr-bench.sock` (+ private XDG)
only INSIDE its own process. A bare `/tmp/herdr-test/herdr-bench pane list` in your shell
uses the default socket = the user's live session (this burned a whole debugging hour:
"bench" agent counts were actually the live session's two real claude panes). Read-only
commands leak real session content; mutating ones would hit real panes. Always prefix:
`HERDR_SOCKET_PATH=/tmp/herdr-test/herdr-bench.sock XDG_CONFIG_HOME=/tmp/herdr-test/xdg-config
XDG_STATE_HOME=/tmp/herdr-test/xdg-state <cmd>`, or add a `cli` passthrough to harness.sh.

## The problem (one paragraph)
herdr's idle CPU was dominated by POLLING loops that woke on timers even when nothing
changed: per-pane detection ticked every 300/500 ms; each PTY actor `poll()`ed its fd
every 50 ms; each attached client's writer thread `recv_timeout(5 ms)` busy-polled two
channels; and idle agent panes forced a full re-render every 800 ms (the frame was
identical and discarded). None of this is a real floor — the expensive work (screen
extraction, agent detection) is already event-driven via PTY output. The fix makes the
idle paths block until a real event instead of polling.

## The fixes (current tip = `slim-fix` branch in ./herdr)

### slim-fix deltas vs clean-fix (this session)
- **Squashed**: one commit on top of master; the "what changed and why" narrative moved
  into the commit message; comments now describe current behavior only (dropped
  "No memoization…", "previously this spun on a 5 ms recv_timeout", etc.).
- **Dropped /proc-read micro-opt** (`src/platform/linux.rs` back to master's
  `read_to_string`): orthogonal to the polling→events rewrite, and the read is now rare
  (gated on generation change / recheck cadence). Verified equivalent output on live
  pids; idle CPU unaffected (see the slim/clean pair above).
- **Dropped `Debug` derive on `WakeWriter`** (`src/pty/fd.rs`): dev leftover, nothing
  needs it; compiles clean without.
- **Added the detection-stall fix** (`src/pane.rs` `should_probe_foreground_job`):
  see the Status box. Cost: one deep probe per 30 s per unidentified pane — noise.
- Everything else (both detection loops, wake, actor, client writer, render gating,
  animation gate, hook-authority gate) is byte-identical to clean-fix and was audited as
  necessary, not cosmetic: each piece removes a distinct polling source.

### PRIOR memos — from the earliest sessions; REMOVED in `clean-fix` (the /proc read
micro-opt survived into `clean-fix` but was dropped in `slim-fix`, see above)
- ~~**detection_text memo**~~ (`src/pane/terminal.rs`): cached grid→text keyed by
  `output_generation`. Dead after the event-driven rewrite: its only callers are the two
  detection loops, which call `detection_text()` exclusively when the generation changed
  since their last extraction — the cache could never hit. Removed in `clean-fix`.
  `output_generation` itself (bumped by `process_pty_bytes`/`resize`) is KEPT — it drives
  the idle fast-path and wake coalescing.
- ~~**detect_agent memo**~~ (`src/pane.rs` `DetectionMemo`): cached text→detection on
  `(agent, content, process_exited)`. On PTY-output wakes the text has changed (miss);
  it only hit on timer ticks (5 s/30 s process rechecks, 800 ms hooked refresh), where one
  `detect_agent` pass is microseconds. Removed in `clean-fix`; behavior-neutral (the
  function is pure, and the publish gate already suppressed duplicate updates).
- ~~**/proc read**~~ (`src/platform/linux.rs` `foreground_process_group_id`): stack-buffer
  scan of `/proc/<pid>/stat` instead of `read_to_string` + Vec collect. Was KEPT in
  `clean-fix`; dropped in `slim-fix` (orthogonal micro-opt, the call is rare now).

### detection idle fast-path — `src/pane.rs` (BOTH detection loops)
At the top of each tick: load `output_generation`; if it is unchanged AND no time-based
process recheck is due AND no stable visible-signal refresh is due, `continue` — skipping
detection_text, the foreground /proc read, and all string compares. When the screen did
change, only then re-extract text; the /proc read is gated on `generation_changed ||
recheck_due`. The two loops are `spawn_basic_detection_task` (used by `from_handoff_fd` →
the live, handoff-imported server) and the inline loop in `spawn_command_builder` (used by
fresh `tab create` → the bench). Optimise BOTH.

### event-driven detection wake — `src/pane/terminal.rs` + `src/pane.rs`
`PaneTerminal` owns a `detection_wake: Arc<Notify>`, fired by `process_pty_bytes`
(when the grid changed) and `resize`. Each detection loop `select!`s on it and replaces
the fixed 300/500 ms sleep with `detection_idle_fallback()` — a long fallback (5 s for an
identified agent, 30 s for a plain shell, 800 ms while a visible signal is held, 500 ms
during acquisition). Idle panes never fire the wake, so their task parks for seconds.

### blocking PTY actor — `src/pty/actor/unix.rs`
The actor's main `poll()` used `ACTOR_POLL_MS = 50`, waking 20×/s/pane. Every command send
already pokes the actor's wake pipe (audited: all `data_tx`/`control_tx` sends call
`wake_actor()`), and PTY output/write-readiness wake `poll()` directly, so the main poll
now uses `ACTOR_IDLE_POLL_MS = -1` (block until a real event). The narrower write-readiness
wait (the `WouldBlock` flush path) keeps the finite `ACTOR_POLL_MS` so a full PTY write
buffer can never deadlock reads. **This single change took detached 3.3% → 0.5%** — the
PTY-actor poll was the dominant floor once detection went event-driven.

### no-op StateChanged must not force a render — `src/app/api.rs` + `src/server/headless.rs`
`handle_internal_event` now returns `bool` (did the event change rendered output?),
computed from the pane update (state/seen/agent-label/presentation diff), toast change, and
other side effects. The headless `StateChanged` arm and the `_ =>` default arm propagate it
instead of always returning `true`. So the 800 ms stable visible-signal refresh and the
1.5 s git-status refresh stop forcing identical full renders. **This took attached 7% → 4.4%.**

### event-driven client writer — `src/server/client_transport.rs`
`client_writer_loop` busy-polled with `recv_timeout(5 ms)` (200 wakes/s/client). Now
`ClientWriter` carries an `Arc<ClientWriterWake>` (Mutex<u64> counter + Condvar); senders
go through `send_control`/`try_send_render` which bump+notify, and the loop drains both
channels then blocks on the Condvar (1 s safety tick). Cross-platform; instant delivery,
zero idle CPU. Control-before-render priority and the cap-1 droppable render are preserved.

### animation timer gated on an attached client — `src/app/runtime.rs` + `src/server/headless.rs`
`agent_panel_has_animation()` hash-scanned every pane each main-loop iteration to drive the
128 ms spinner tick — even detached, where nothing renders. `sync_animation_timer_headless`
now only scans when `has_app_client()`, else clears the timer.

### hook-authority refresh gate — `src/pane/terminal.rs` + `src/pane.rs` + `src/app/api.rs` (the `full-fix` addition)
The 800 ms `STABLE_VISIBLE_SIGNAL_REFRESH` woke each idle agent pane ~1.25×/s to republish
its (unchanged) screen state. Its only purpose is reconciling screen signals against a
stale hook authority (`fallback_observed_at` freshness + the `stale_hook_idle_since`
window in `src/terminal/state.rs`); without a hook authority the republish is a pure
no-op app-side. Now `PaneTerminal` carries a `hook_authority_present: AtomicBool`;
`App::sync_hook_authority_presence` (in `src/app/api.rs`) pushes
`TerminalState::hook_authority.is_some()` down to the pane runtime after every event that
can set/clear it (`StateChanged`, `HookStateReported`, `HookAuthorityCleared`,
`HookAgentReleased` — the ONLY set path is `HookStateReported`, and all production paths
flow through `handle_internal_event`). Both detection loops gate the refresh due-check,
the publish-side `stable_refresh_due`, and the 800 ms idle fallback on the flag; setting
the flag fires `detection_wake` so a parked task resumes the refresh cadence immediately
when a hook report arrives. Fresh/restored/handed-off runtimes start with the flag off,
matching `hook_authority: None` (hook authority is never persisted or handed off — restore
only carries `persisted_agent_session`). Idle agent panes without hooks now park on the
5 s process-recheck fallback. A missed clear-site would only cost extra refreshes (old
behavior); the stale-hook screen-veto was verified end-to-end on the bench: `pane
report-agent <id> --source test-hook --agent claude --state working` on an idle-screen
agent pane flips to working immediately and back to idle ~4 s later (veto needs the
2 s `STALE_HOOK_IDLE_GRACE` after the post-report refresh resumes).

## Cleanup audit (the `clean-fix` pass) — what was checked and the verdicts
- ~~detection_text memo~~ / ~~DetectionMemo~~ — REMOVED (see PRIOR memos above).
- **idle fast-path** — KEPT. Still load-bearing for timer wakeups (5 s/30 s rechecks,
  800 ms hooked refresh, 50 ms pending-release ticks) and for coalesced wake
  notifications, where the grid is unchanged and extraction must be skipped.
- **animation timer gate** (no-client-specific) — KEPT. The idle measurements don't
  exercise it: with a WORKING agent while detached, the ungated 128 ms spinner tick
  would full-render *virtually* 7.8×/s — `render_and_stream` renders even with zero
  clients ("rendered virtual frame with no attached clients").
- **handle_internal_event bool** (no-op render skip) — KEPT. Load-bearing while
  attached: the 1.5 s git-status refresh (upstream cadence) almost always changes
  nothing; in master the loop still forced a full render per tick because
  `handle_internal_event_with_forwarding` returned an unconditional `true`.
- **blocking PTY actor / client-writer Condvar / hook-authority gate / /proc read** —
  KEPT, all core.

## Open question (2026-07-01, from portable-harness design discussion)
Git status is displayed **per workspace, not per pane** (confirmed by Suor). Check whether
our idle-CPU fixes actually account for this: do we still do per-pane git-status refresh
work (discovery walk / fingerprint check / ahead-behind) that's redundant given the
per-workspace display, or is the refresh already scoped/deduped at the workspace level?
If per-pane panes sharing a workspace+repo are doing duplicate git-status work that never
shows up (because only the workspace-level result is rendered), that's a possible extra
idle-CPU shave — but NOT yet investigated, don't assume either way.

## Remaining floor
The headless loop wakes ≥4×/s because the client-accept listener is POLLED:
`CLIENT_ACCEPT_POLL_INTERVAL = 250 ms` (upstream design, present in pristine master —
the unix listener is non-blocking and not in the `tokio::select!`; Windows already uses
an accept thread that pushes events). Event-ifying unix accept the same way would remove
the last periodic wake. The rest is tokio's timer driver + `clock_gettime` base plus the
5 s/30 s process-recheck cadence. Also note (upstream behavior, untouched): the server
renders virtually on PTY-output even with no clients attached.

## Verification done
- `cargo test --release --bin herdr`: 1967/1967 (binary crate — use `--bin herdr`, not
  `--lib`); includes the new `hook_authority_presence_is_synced_to_the_pane_runtime`.
- `cargo clippy --release --bin herdr`: clean for changed code (one pre-existing warning at
  `src/app/actions.rs:2550`, not touched by this work).
- Harness A/B above (monstro vs full, clean vs full, slim vs clean — back-to-back
  pairs); client frame delivery (verify_delivery.py exit 0) on full-fix and slim-fix;
  stale-hook screen-veto e2e verified on full-fix and clean-fix (slim-fix does not touch
  that path beyond the probe-cadence fix).
- Detection-stall fix verified on the bench: slim-fix identifies 4/4 agents in 3/3 runs
  (~26 s worst case); clean-fix same hour: 0–2 of 4, stuck until a repaint.

## Harness (in /home/suor/projects/herdr-fix)
`harness.sh` commands (set `SRV_ENV="HERDR_RENDER_PROF=1 HERDR_LOG=herdr=info HERDR_DISABLE_SOUND=1"`
to log per-second render counts to `/tmp/herdr-test/xdg-config/herdr/herdr-server.log`):
- `start` / `stop`  — bench server (separate `herdr-bench` copy, private socket/XDG)
- `panes [N]`       — create N idle panes across many cwds (default 40; use 43)
- `agents [N]`      — turn the first N panes into IDLE claude agents (runs a renamed `cat`
                      named `claude` so the process-probe identifies it; prints a realistic
                      idle-claude screen so detect_agent runs its full path)
- `attach [C R]`    — headless client under a fixed-size PTY (default 250×64; use 190 47 to
                      match the live terminal); `detach` kills it
- `cpu [secs]`      — CPU% of server + client + combined (this is the real measurement)
- `agentcount`      — how many panes herdr currently sees an agent in
Support files: `attach.py` (PTY client launcher), `claude-idle-screen.txt`, `panestat.py`
(per-pane revision/agent snapshot), `verify_delivery.py` (proves the client receives a frame
when a visible pane changes). The OLD `run_exp.sh` has an UNSAFE path-based `pkill` — do NOT
use it; use `harness.sh`.

Typical faithful run:
    SRV_ENV="HERDR_RENDER_PROF=1 HERDR_LOG=herdr=info HERDR_DISABLE_SOUND=1" ./harness.sh start
    ./harness.sh panes 43 && ./harness.sh agents 4
    ./harness.sh cpu 12                 # detached
    ./harness.sh attach 190 47 && ./harness.sh cpu 12   # attached

### Why the OLD numbers were "way off"
The previous harness measured 41 idle SHELL panes with NO client → it never exercised the
agent-detection path or the attached render path (the two biggest real costs). The faithful
harness adds idle agent panes + a real attached client and measures server+client CPU; it
now reproduces the live 3.0%/7.8% before the fixes.

## Profiling
    timeout 30 perf record -g -o /tmp/p.data -p <bench-server-pid> -- sleep 15
    perf report -i /tmp/p.data --stdio -g none --sort=symbol | head -25   # flat self-time
Profile the BENCH server PID only, never the live server. CPU is low now, so use a long
window (≥15 s) for enough samples.

## NEXT STEPS
1. **(Low urgency) live-handoff the production server** from `herdr-slim-probe-fix`
   (current; already has the stall+probe fixes) to a newer variant — now preferably
   `proper-fix` (slim-fix + non-idle wins, see REPORT.md):
       herdr server live-handoff --import-exe ~/.local/bin/herdr-proper-fix
   Verify `herdr pane list` shows all panes and the new server PID's CPU stayed low.
   Rollback: `herdr server live-handoff --import-exe /usr/bin/herdr`
   For bench-only A/B instead: `SRC=~/.local/bin/herdr-<variant> ./harness.sh start`
   (the harness copies SRC to its isolated `herdr-bench`).
2. **Upstream PR** (author invited it on #439). Repo: ogulcancelik/herdr. Push the
   `slim-fix` branch (one squashed commit; the commit message already tells the full
   story) and open the PR from it. Framing: idle CPU was polling, not a floor — make
   detection wake on PTY output, the PTY actor block until an event, the client writer
   block on a Condvar, skip renders for no-op state updates, and republish held screen
   signals only while a hook authority exists; plus the probe-cadence fix the rewrite
   requires (silent-exec stall). Mention input latency + frame delivery are preserved
   and the win is ~12× on an idle multi-pane session. The `proper-fix` commits
   (debounce + visibility gating) could be a follow-up PR once the first lands.
3. **(Optional follow-up, upstream-design change)** event-ify unix client accept (mirror
   the Windows accept thread) to remove the 250 ms `CLIENT_ACCEPT_POLL_INTERVAL` wake —
   the last periodic wake in an idle server. Probably best raised in the PR discussion
   rather than bundled into it.

## Rebuild from source
    cd herdr && git checkout proper-fix   # or slim-fix / old-fix / triple-fix / monstro-fix / full-fix / clean-fix
    ZIG=$(pwd)/../zig-x86_64-linux-0.15.2/zig cargo build --release --bin herdr
Leave the repo on `proper-fix` when done (it is the current/default working state;
`target/release/herdr` currently holds the proper-fix build).
