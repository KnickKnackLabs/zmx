# KnickKnackLabs fork delta

This repository tracks [neurosnap/zmx](https://github.com/neurosnap/zmx)
while preserving a small set of KnickKnackLabs consumer contracts.
Keep the delta explicit so an upstream sync does not silently remove behavior
or replay obsolete fork history.

## Runtime contracts

### `zmx-control/v1`: restored

The generic binary terminal-adapter protocol is owned under `src/control/`.
Its public five-byte frame format is separate from zmx's internal IPC tags.
The client supports current KKL daemons and the previous released KKL daemon
without sending a legacy tag into an unclassified current daemon.

Validation lives in Zig protocol and daemon tests,
`test/control.bats`,
and consumer smokes.

### `list --json`: restored

Shell and other automation require a stable JSON array from `zmx list --json`.
The contract includes session name,
status,
PID,
client count,
exit code,
creation time,
current-session state,
start directory,
and command.

Human-readable upstream list output remains the default.
The machine contract lives in `src/list.zig`
and is covered by unit and BATS tests.

### Long `run` input: restored on current upstream

Current upstream fixed terminal-width preservation and readline truncation,
but real Shell launchers still exposed timing-sensitive loss while a large line
was delivered to an interactive shell.
`src/pty_run_pacer.zig` owns bounded PTY delivery for `run` input.
The behavioral suite pins a 4,000-byte argument through interactive readline.

### Terminal semantics: restored where still needed

The fork retains terminal-query responses,
OSC 133 prompt redraw handling,
viewport and live control frames,
history framing,
and command-on-create output ordering.
These behaviors are integrated with current upstream terminal and daemon APIs
rather than copied as old monolithic control code.

## Replaced fork code

Current upstream now owns the daemon,
PTY,
task,
label,
`send`,
`print`,
`write`,
`wait`,
`tail`,
and human-readable list implementations.
The old KKL `src/list.zig` table renderer,
`src/output.zig`,
zig-clap migration,
and their historical patch sequence are not replayed.
Only the still-consumed JSON list contract was restored on the current structure.

The old standalone `rm` command is retired.
Current `kill --force` and stale-socket handling own that lifecycle boundary,
and no maintained KKL consumer calls `rm`.

## Repository automation

### CI: replaced

`.github/workflows/ci.yml` validates Zig 0.16 formatting,
compilation,
unit tests,
the executable build,
and BATS on macOS and Linux.
It replaces the old Zig 0.15 workflow.

### Upstream sync: retired

The old scheduled workflow rebased and force-pushed `main`.
It is intentionally not restored.
Upstream updates are migrations:
start from an inspected exact upstream ref,
port the explicit KKL delta,
run consumer validation,
and merge through review.

### Release workflow: retired pending replacement

The old release workflow targeted Zig 0.15 and historical artifact assumptions.
It is intentionally not restored.
A local Zig 0.16 cross-platform build exposed severe contention when all four
ReleaseSafe targets compiled without a job bound.
Each Linux target completed independently in under two minutes,
and `zig build release -j1` produced all four archives in under two minutes
with a warm dependency cache.
The build now writes portable checksum entries that name the distributed archive
rather than Zig's temporary cache path.

A future release workflow should build a bounded target matrix or use `-j1`,
verify each archive and checksum,
and run real Shell and terminal-adapter consumers against the exact candidate.
No KKL release should be published until that replacement path is reviewed and proven.
