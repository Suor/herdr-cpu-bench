# Agent instructions

This repo benchmarks herdr's idle CPU. **The full procedure lives in [`README.md`](README.md)
— follow it, don't restate it here.**

When asked to "measure / compare / benchmark" herdr variants — e.g. *"compare herdr master
with Suor's fixed version"*:

1. **Build** each variant per README's "Quick start" (`./build.sh <ref> <label>`; baseline
   is `master`, Suor's fix is `proper-fix`). Build any extra ref the user names.
2. **Measure** each binary with the harness commands in README, back-to-back in one
   session. Take ≥2 `cpu` samples per cell — absolute % drifts with machine load, only
   within-session differences are meaningful.
3. **Report** a markdown table: one row per variant, detached + attached CPU% (from the
   `cpu` output), plus a one-line note on what each was built from.

Hard constraints (see README's "Safety model" for why):

- Never invoke the built `herdr` binary or a bare `herdr` client directly — always go
  through `harness.sh`, or you may hit a real, live herdr session on the machine.
- Never `pkill`/`kill` herdr by path or name pattern; use `./harness.sh stop` only.
