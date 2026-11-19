# Build time of optimized builds (DESIGN 12.21)

Compiler: nightly-2026-11-14-a87808d. basic-cli 0.28.1. All runs through `scripts/roc.sh`
(16 GB cap, 600 s timeout), one at a time; the machine load (1-minute average) was 4 to 6
during every run, as other jobs shared the machine.

## Finding

`roc build` (default `--opt=speed`; `--opt=size` behaves the same) runs SpecConstr with
`all_calls` clone inlining (`specConstrCloneInliningForOpt`) and the `.wrappers` inline mode,
which inlines every body the whole program calls once (`postCheckInlineModeForOpt`). A body of
fewer than 200 expressions that is called with a constructor the compiler knows (a tag such as
`Ok(st)`, a record literal or update, a lambda) is cloned into a call-pattern worker or inlined
where the known value "crosses productively", and the clone inlines its own callees the same way.
Nothing bounds the total size. In the SDK the engine's handlers collapsed into one procedure per
caller, several times over: `examples/hello.roc` got one 1.5 MB function (`Stdio.serve!` with
the engine inside it), and LLVM spent 375 s on it (SROA 154 s, LoopRotate 83 s), RSS 3.8 GB.
The LIR passes (`Specializing`) are superlinear in the size of one procedure too: 60 s for the
`receive.roc` app below.

`--opt=dev` builds the same apps in 1 to 2 s: it uses `iterator_fusion` SpecConstr and the
`procedures` inline mode.

## Workaround

A body that contains a non-tail `return` is never inlined: SpecConstr's `stepInlineDirect`
refuses it (`exprContainsReturn`), and so does the single-use inliner (`contains_return` in
`postcheck/solved_inline.zig`). A tail `return` does not count: the compiler reports it as a
redundant return and drops it. The SDK starts each engine function that takes `Server.Parts`,
and the recursive `SchemaCheck` functions, with an early `return` guard.

## Measurements (wall time of `roc build --timings --no-cache`)

| App | Before | After | Notes |
| --- | --- | --- | --- |
| `examples/hello.roc` | killed at 600 s (single core busy all the time) | 24 s | after: LLVM 22.6 s, largest proc 89 KB |
| `examples/hello.roc`, `SchemaCheck.validate` stubbed | 404 s (LLVM 375 s, Specializing 26 s, largest proc 1561 KB) | 18 s | |
| `examples/everything.roc` | over 600 s (task report) | 29 s | |
| `receive.roc` (one `Engine.receive`, no tools) | 83 s (Specializing 60 s, LLVM 21 s) | | `--opt=dev`: 0.9 s; `--opt=size`: 76 s |
| `schemacheck.roc` (only `SchemaCheck.validate`) | 15.6 s (SpecConstr 30 452 expressions, two 152 KB procs) | 7 s (6 315 expressions, largest proc 34 KB) | |
| `json.roc` (only `JsonValue`) | 1.1 s | | baseline |

SpecConstr's "Expressions committed" counter (printed by `--timings`, "Shared SpecConstr parallel
execution") shows the growth before any later stage: `receive.roc` 566 773 with `--opt=speed`
against 6 393 with `--opt=dev`.

## Synthetic repro (no package)

`gen_repro.py N plain|return` writes a headerless program (Echo platform) with the engine's
shape: a dispatcher called with `Ok(st)` and `Err(NoState)`, N handlers each called once, small
helpers over a known record. The `return` variant adds one early `return` to each handler and
computes the same thing. `repro_plain.roc` and `repro_return.roc` are N = 30 (then `roc fmt`).

| Program | `--opt=speed` | Procedures in the binary | SpecConstr expressions | `--opt=dev` |
| --- | --- | --- | --- | --- |
| `repro_plain.roc` (N = 30) | 13 s (LLVM 11.8 s) | 5, one of 203 KB | 96 448 | under 1 s |
| `repro_return.roc` (N = 30) | 4 s (LLVM 3.7 s) | 125, largest 19 KB | 36 458 | under 1 s |
| N = 60, plain | 5 s | 7, one of 263 KB | 17 048 | under 1 s |
| N = 60, return | 4 s | 127, largest 5 KB | 17 768 | |

The synthetic program shows the collapse into one procedure, but not the SDK's full blow-up (the
per-function worker budget stops it sooner at N = 60); the SDK numbers above are the evidence for
the size of the effect.

## Tools

- `time_build.sh <app.roc>... [-- roc args]`: timed `--timings --no-cache` builds; logs in `.tmp/ct/`.
- `codesize.py <binary>...`: the number and sizes of the Roc procedures (`roc__p*`) in a binary.
  The largest one is the procedure the inliners grew.
