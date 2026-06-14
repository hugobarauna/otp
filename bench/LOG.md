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

### E1 — op reader 1/2-byte fast path in beamreader_read_tagged — REVERTED
Hypothesis: single bounds check + likely-hints for the dominant 1-2 byte
operand encodings would cut beamcodereader_read_next self time (~5%).
Result: load min 458,231 (-1.4% vs 452,044 baseline = worse), prepare min
370,628 (worse). GCC already optimizes this path well; extra code hurt
layout. Decision: revert.

### E2 — incremental staged-table sync (erl_code_staged.h) — KEPT
Hypothesis: per-load O(export table) rescan in start_staging is wasted work;
append-only tables allow tail-only membership sync + dirty-list address
refresh. Result: load min 452,044 -> 432,072 (-4.4%), median 476,307 ->
447,509 (-6.0%); prepare/finish unchanged as expected. verify hash OK,
stress gauntlet (reload/purge/delete/trace/funs/on_load/atomic/concurrent)
passes 3/3. New reference: load min 432,072. Commit on branch.

### E3 — batched atom insertion (erts_atom_put_many) — REVERTED
Hypothesis: verifying UTF-8 outside the lock + chunked single-write-lock
inserts (skipping the read-locked probe) would recover part of the ~4%
erts_atom_put cost. Result: A/B prepare min 363,447 (base) vs 366,405
(patch), medians 381,087 vs 375,229 — a wash within noise; the per-atom
rwlock+double-hash overhead is evidently not the dominant part of
erts_atom_put (hash+memcmp+text copy dominate). Decision: revert.

### E6 — pre-reserve asmjit text CodeBuffer (8x BEAM code size) — REVERTED
Hypothesis: avoid grow+copy cycles during codegen (malloc 2.1%).
Result: A/B prepare min 367,255 (base) vs 371,245 (patch) — slightly worse;
asmjit's default growth policy is evidently not a bottleneck. Decision:
revert.

### E7 — O(1) fragment lookups (flat GlobalLabels arrays + open-addressed
### per-module dispatch table) — KEPT
Hypothesis: two unordered_map lookups per emitted fragment call (ga get()
+ resolve_fragment) are hot enough to matter. Result: A/B load min 440,857
-> 419,230 (-4.9%), median -4.1%; prepare min -2.0%. verify + stress OK.
New reference: load min ~419,230 (A/B conditions). Commit on branch.

### E8 — rawLabels: unordered_map -> vector<Label> — KEPT
Dense label keys; per-label-operand hash lookups removed. prepare min
357,670 -> 349,898 (-2.2%); load median -1.8% (ABAB rounds, min noisy).
verify + stress OK. Reference now: load min ~404-425k (noisy), prepare
min ~349,898.

### E9 — cheap JIT metadata registration (register_metadata) — KEPT
register_metadata was ~5.8% of load: under-reserved ranges vector,
printf-based %T name formatting per function, per-line-entry file name
conversion, copied line vectors. Fixed all four (no behavior change; gdb
symfile content identical). A/B: load min -2.7%, median -5.4%. verify +
stress OK. Reference: load min ~398k, median ~416k.

### E10 — LineData file names by pointer + lines reserve — KEPT
Per-line-entry std::string heap copies removed (pointer into per-module
file_names cache); lines vector reserved from func_tab bounds. A/B: load
min -1.9%, median -6.3%. verify + stress OK. Reference: load min ~390k,
median ~404k.

### E11 — unrolled MD5 transformation — KEPT (small, certain)
End-to-end ~-1% (at noise floor; below the usual 1.5% bar) but mechanism
verified directly: erlang:md5 on 64MB 143ms -> 112ms (-22%), digests
identical. Profile predicted ~1% and measurement agrees, so kept as a
deterministic improvement.

### Debug-build validation (E2 et al)
Built TYPE=debug FLAVOR=jit emulator; registered the new staged dirty
locks in erl_lock_check.c (own levels: after staging rwlocks, before
alcu_allocator). verify + full stress gauntlet pass under the debug
emulator — including the DEBUG-only full-scan staging assertions added in
E2 and the lock-order checker.

### Boot-time checkpoint
bin/erl -noshell -eval halt(): master best 0.19s -> branch best 0.17s
(~10% faster real-world VM boot).

## Final results (2026-06-12 night)

Back-to-back master vs branch (idle machine, n=15):
- load:    min 458,580 -> 382,571 us (-16.6%); median 486,960 -> 409,154 (-16.0%)
- prepare: min 368,361 -> 343,088 us (-6.9%);  median 381,535 -> 360,174 (-5.6%)
- VM boot: best 0.18s -> 0.16s (~-11%)

Validation: verify hash identical throughout; stress gauntlet green on opt
and TYPE=debug emulators (incl. E2's debug-only staging assertions and the
lock checker); kernel code_SUITE 56 ok / 0 failed / 1 env-skip.

Patch series: bench/patches/ (git format-patch master..code-loading-opt).

### E12 — drop asmjit kOptimizeForSize encoding option — REVERTED
Hypothesis: size-optimization branches add per-instruction encode cost we
don't need for a loader. Result: interleaved A/B prepare min — PATCH
349,541/350,253 vs BASE 348,533/357,345 — identical at the min. The BEAM
JIT's instruction mix rarely hits the size-opt branches, so _emit cost is
fundamental encoding (InstDB lookup + ModRM/REX/imm writing), not config.
Decision: revert. Implication: asmjit config tuning won't move _emit;
need codegen-level or fixup-level changes.

### E13 — transform-engine gate for label/aligned_label — REVERTED (correct but sub-noise)
Instrumented the engine: label = 166,520 calls / 528 transforms (99.7% fail),
aligned_label = 35,351 / 261 (99.3% fail) — they only transform when followed
by a receive op (loop_rec/wait/wait_timeout/timeout). Added a provably-correct
pre-filter (transform_may_match) with a DEBUG ASSERT cross-checking the engine
agrees. verify hash identical, stress green. But A/B (load 4/4 weakly positive
~1.6% min; prepare 3 ABAB rounds: patch min -2.9%/+0.2%/+2.9% vs base — a
wash). Per-call overhead (~30 cyc × 200k = ~2ms) is below the ~3% run-to-run
noise. Each saved call is cheaper than an average (productive) call, so cutting
15% of calls cuts <1% of engine time. Decision: revert — not decidedly better.
Note: func_info does NOT reach the engine (it's synthesized into int_func_start
in beamcodereader_next before load_code), correcting the subagent's assumption.

## Scaling result (the real headline) — 2026-06-14

The speedup grows with module count because E2 removes a super-linear
per-module staging cost. Interleaved master-vs-branch, 2 rounds, min of 8:

| modules | master µs | branch µs | speedup |
|---|---|---|---|
| 100 | 453,357 | 372,082 | -17.9% |
| 200 | 991,570 | 764,880 | -22.9% |
| 400 | 2,257,331 | 1,549,233 | -31.4% |

Master per-module: 4534 -> 4958 -> 5643 µs (super-linear). Branch: 3721 ->
3824 -> 3873 µs (flat/linear). Confirmed by profiling master @ N=400:
export_start_staging = 12.08% of load (vs ~3% @ N=100), #2 after asmjit
_emit (14%). E2 makes that O(new) not O(table) -> the win scales with N.

Lean codegen-heavy workload @100 modules: -13..17% (interleaved), robust
to workload shape. The earlier 27% one-off was cross-time/cron noise.

This session also tried E12 (kOptimizeForSize, reverted) and E13
(transform gate, correct but sub-noise, reverted). Net new finding: the
existing 6 patches already deliver far more than 16% at realistic scale.
