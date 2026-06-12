# Code loading optimization — experiment log

Methodology (after karpathy/autoresearch): one fixed benchmark, one scalar
metric, one change per experiment; rebuild → measure → keep if decidedly
better, revert if not. Every experiment is logged here.

## Benchmark

- Workload: 100 generated modules (`bench/gen_modules.escript 100 100 src`),
  each with 100 f/1 + 100 g/2 functions, ~200 exports, unique atoms,
  string/binary/map literals, compiled with the in-repo erlc (OTP 30, JIT).
- Metric: microseconds to load all 100 .beam binaries in a fresh VM
  (`bench/bench.sh ITER MODE`); fresh VM per sample; report min/median.
  - `load` (primary): sequential `erlang:load_module/2` — real-world path.
  - `prepare`: `erlang:prepare_loading/2` only (parse + JIT codegen).
  - `finish`: one batched `erlang:finish_loading/1` (staging commit).
- Machine: 4-core x86_64 Linux (home server; min-of-N used to reject noise).
- Rebuild: `make emulator` (~2.5 s incremental).

## Baseline (commit b0b807820f)

| mode | min | median |
|---|---|---|
| load | 461,841 | 484,197 |
| prepare | 370,551 | 371,992 |
| finish | 48,194 | 50,246 |

prepare ≈ 80% of load. perf (prepare): asmjit `Assembler::_emit` 16% self,
`beamcodereader_read_next` 4.8%, `hash_part`+`hash_get` 5.5%,
`beam_load_emit_op` 3.7%, `erts_transform_engine` 3.7%, asmjit label/fixup
2.4%, `erts_move_multi_frags` 1.1%, malloc ~1%. (`scheduler_wait` 11.7% =
idle schedulers, not loader work.)

## Experiments

(one entry per experiment; keep = committed on branch `code-loading-opt`)
