# herdr idle-CPU investigation — findings

## TL;DR
The dominant idle-CPU cost is **`PaneTerminal::detection_text()` re-extracting the
entire terminal grid every detection tick** (per-cell FFI grapheme reads + string
building), for every pane, ~3.3×/s, **regardless of whether the screen changed**.
It scales with grid size (rows×cols), so large terminals with many panes burn a lot.

`/proc/<pid>/stat` polling and git status refresh — the things everyone chased
because they're what `strace` shows — are minor (~0.8% and ~1% respectively).
The real cost is userspace grid extraction, invisible to `strace`, visible only
under a CPU profiler with symbols.

## Method
- Built herdr 0.6.8 from source (zig 0.15.2 for vendored libghostty-vt).
- Isolated test server (private `XDG_CONFIG_HOME`), restored a clone of the real
  session (6 workspaces, 40 panes, same cwds), attached a 250×64 client to give
  panes a realistic large grid.
- Measured server CPU via `/proc/PID/stat` utime+stime deltas.
- Isolated each suspected cause with env-gated short-circuits, one rebuild.

## Measurements (40 panes, 250×64 grid, big client attached)
| Variant | CPU | Δ vs baseline |
|---|---|---|
| baseline | 12.4% | — |
| disable /proc read (foreground_process_group_id → None) | 11.6% | −0.8% |
| disable git refresh | 11.4% | −1.0% |
| **disable detection_text extraction** | **4.9%** | **−7.5%** |
| disable proc + detection_text | 4.0% | −8.4% |
| **FIX: memoize detection_text by output generation** | **5.0%** | **−7.4%** |

Smaller panes (80×24) showed proc-read and detection_text roughly equal (~13–14%
of a 6% total ≈ ~0.8% each absolute) — confirming detection_text scales with grid
size while the /proc read is a fixed per-pane cost.

## Root cause (code)
`src/pane.rs` detection loops (both the normal `tokio::spawn` task ~line 1601 and
`spawn_basic_detection_task` ~line 396 used for handoff/restored panes) call
`terminal.detection_text()` every tick. That walks `rows × cols` cells via
`ghostty_screen_row` → `screen_graphemes(x,y)` FFI per cell and builds a String —
even when no new PTY bytes have arrived. `content_changed` is computed *after* the
extraction, so the cost is paid unconditionally.

## Fix
Memoize `detection_text()` on an output-generation counter:
- `GhosttyPaneTerminal` gains `output_generation: AtomicU64` (bumped on non-empty
  `process_pty_bytes` and on `resize`) and `detection_cache: Mutex<(u64, String)>`.
- `detection_text()` returns the cached string when the generation is unchanged,
  so idle panes (no new output) skip the grid walk entirely.

Behaviorally transparent: the grid hasn't changed between same-generation ticks, so
the returned text is identical to what would have been recomputed. Scroll doesn't
affect detection_text (it reads the logical bottom rows, not the viewport), so it
needn't bump the generation.

Result: **12.4% → 5.0%** here (~60% reduction); larger on bigger grids. The
residual ~5% is tokio/poll + client frame streaming + the minor proc/git costs.

## Notes on proc/git (the previously-suspected causes)
- The full `/proc` enumeration (issue #300) is already gone; the remaining
  per-pane `/proc/<pid>/stat` read is ~0.8% — not worth the risk of reworking the
  detection state machine. (A `tcgetpgrp(master_fd)` swap, per #300, is possible but
  marginal; `foreground_process_group_id_for_tty_fd` already exists, just unused.)
- git refresh is ~1% and only runs while the event loop is kept awake by pane
  output anyway.
