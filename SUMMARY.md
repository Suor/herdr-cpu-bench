# herdr idle-CPU: investigation + fix (summary for Suor)

## What was wrong
Dominant idle-CPU cost = `PaneTerminal::detection_text()` re-extracting the whole
terminal grid (per-cell FFI grapheme reads + String build) **every detection tick
(~3.3×/s per pane), regardless of whether the screen changed**. Cost scales with
grid size (rows×cols) × pane count → big terminal + many panes = lots of CPU.

`/proc/<pid>/stat` polling (~0.8%) and git refresh (~1%) — what strace shows and
what issues #300/#439/#353 chased — are minor now. The real cost is userspace grid
extraction, invisible to strace, visible only under `perf` with symbols.

## Proof (40-pane clone of your session, 250×64 grid, big client)
- baseline (built 0.6.8): **12.4%**
- disable /proc read: 11.6% (−0.8%)
- disable git: 11.4% (−1.0%)
- disable detection_text extraction: 4.9% (−7.5%)  ← the cause
- **FIX (memoize detection_text): 5.0% / final clean build 4.8%**  (~61% cut)

Smaller 80×24 panes showed /proc and detection_text ~equal — because detection_text
scales with grid size while the /proc read is fixed per pane. Your real panes are
large, so detection_text dominates (your server was ~33%).

## The fix (src/pane/terminal.rs, +33 lines — see fix-detection-text-memoization.patch)
- `GhosttyPaneTerminal` gains `output_generation: AtomicU64` + `detection_cache: Mutex<(u64,String)>`.
- generation bumped on non-empty `process_pty_bytes` and on `resize`.
- `detection_text()` returns the cached string when generation is unchanged → idle
  panes skip the grid walk. Behaviorally transparent (grid unchanged ⇒ same text;
  scroll doesn't affect detection_text so it needn't bump).

## Verification
- `cargo test --release` lib suite: **1966/1966 pass** with the fix.
- The only other failures (1 worktrees test, 2 cross_area integration tests) fail on
  **pristine** code too in this environment → pre-existing/environmental, not the fix.

## Artifacts (in /home/suor/projects/herdr-fix)
- `herdr/` — cloned source with the fix applied
- `herdr/target/release/herdr` — built fixed binary (0.6.8 + fix)
- `fix-detection-text-memoization.patch` — clean PR-ready diff
- `FINDINGS.md` — detailed write-up
- `harness.sh`, `run_exp.sh` — isolated test harness used for measurements
- zig 0.15.2 at `zig-x86_64-linux-0.15.2/` (needed to build vendored libghostty-vt)

## Upstream
The author (ogulcancelik) invited a PR on #439. This patch is PR-ready. Suggested
framing: idle CPU is dominated by detection_text grid extraction every tick, not the
/proc scan; memoizing on an output-generation counter cuts it ~60% (numbers above).

## To build from source again
    cd herdr && ZIG=$(pwd)/../zig-x86_64-linux-0.15.2/zig cargo build --release

## Rollback (if the running server was handed off to the fixed binary)
    herdr server live-handoff --import-exe /usr/bin/herdr
