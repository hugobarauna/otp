# Optimizing Erlang/OTP module loading (erts) — results

Branch: `code-loading-opt` (based on `master` @ b0b807820f).
Method: autoresearch-style loop — one fixed benchmark, one scalar metric,
one change per experiment, measure → keep-or-revert, log everything
(bench/LOG.md has the full experiment log, including failures).

## Benchmark

100 generated modules, ~200 functions each (bench/gen_modules.escript),
compiled with the in-repo erlc. Metric: wall time to load all 100 .beam
binaries in a fresh VM via sequential `erlang:load_module/2` (the
real-world code-server path), min/median over 10–15 fresh-VM runs;
keep-decisions confirmed by direct A/B (rebuild base ↔ patch, interleaved).
Secondary modes: `prepare` (parse + JIT codegen only) and batched `finish`.
Machine: 4-core x86_64 Linux, OTP 30 master, JIT (beamasm).

## Headline result

The speedup is **not a fixed 16% — it grows with the number of modules
loaded**, because the patches remove a *super-linear* per-module cost in the
loader (see "Scaling" below). Loading 100 modules is ~16-18% faster; loading
400 modules (≈ the size of OTP's own boot set, and small for a real
Elixir/Phoenix app) is **~31% faster**.

### Scaling (interleaved master-vs-branch, 2 rounds, min of 8 fresh VMs each)

| modules loaded | master (µs) | branch (µs) | speedup | master µs/mod | branch µs/mod |
|---|---|---|---|---|---|
| 100 | 453,357 | 372,082 | **-17.9%** | 4,534 | 3,721 |
| 200 | 991,570 | 764,880 | **-22.9%** | 4,958 | 3,824 |
| 400 | 2,257,331 | 1,549,233 | **-31.4%** | 5,643 | 3,873 |

Master's per-module cost grows +24% from 100→400 modules (super-linear total);
the branch is essentially flat (+4%, i.e. linear total). Root cause confirmed
by profiling master at N=400: `export_start_staging` — the loader rescanning
the entire (growing) export table on *every* `finish_loading` — is **12% of
load time at 400 modules** (vs ~3% at 100), the #2 cost after the asmjit
encoder. Patch E2 makes that sync O(newly-added entries) instead of
O(whole-table), removing the quadratic term. So the more modules a system
loads, the larger the win. Reproduce with `bench/scaling.sh` +
`bench/load_count.escript` against a 400-module set
(`bench/gen_modules.escript 400 100 bench/src_scale`).

### Fixed 100-module benchmark (the original metric)

Back-to-back master-vs-branch (idle machine, n=15 fresh VMs):

| metric | master | branch | change |
|---|---|---|---|
| load min | 458,580 µs | 382,571 µs | **-16.6%** |
| load median | 486,960 µs | 409,154 µs | **-16.0%** |
| prepare min | 368,361 µs | 343,088 µs | -6.9% |
| prepare median | 381,535 µs | 360,174 µs | -5.6% |
| VM boot (best of 12) | 0.18 s | 0.16 s | ≈-11% |

A second, codegen-heavy "lean" workload (many functions, few unique
atoms/literals; `bench/gen_lean.escript`) loads ~13-17% faster on the branch
at 100 modules — confirming the gains are robust to workload shape, not an
artifact of the atom-heavy fixture.

- `erlang:md5/1` throughput: +28% (143 ms → 112 ms / 64 MB), a side
  benefit of E11.

## Kept patches (in commit order)

1. **Incremental staged-table sync** (`erl_code_staged.h` + mark-dirty call
   sites). `erts_start_staging_code_ix` rescanned the entire export/fun/
   record staged index tables on every staging cycle — O(table size) per
   loaded module. The tables are append-only, so membership now syncs by
   appending only entries added since the destination table was last
   synced, and per-object staged state (dispatch addresses, record defs)
   is refreshed only for objects modified in the last two staging
   generations, tracked via `mark_dirty` at every write site (loader,
   delete_code, purge, breakpoints, on_load fixups). −4.4% load min.
   Validated additionally under a TYPE=debug build whose DEBUG-only
   assertions re-verify the full-scan equivalence on every staging.

2. **O(1) fragment lookups in JIT codegen** (x86 `beam_asm_global.hpp.pl`,
   `beam_asm.hpp`, `beam_asm_module.cpp`). Per emitted fragment call the
   loader did two unordered_map lookups (GlobalLabels→fnptr, then
   fnptr→veneer Label) — millions per 100 modules. Replaced with a flat
   std::array for the global assembler and a fixed 512-slot open-addressed
   probe table per module. −4.9% load min, −4.1% median (A/B).

3. **BEAM labels: hash map → vector** (`beam_jit_common.{hpp,cpp}`).
   Label numbers are dense; `rawLabels` was an unordered_map consulted for
   nearly every emitted instruction. −2.2% prepare min.

4. **Cheaper JIT metadata registration** (`beam_jit_common.cpp`).
   `register_metadata` (perf/gdb JIT interface) was ~6% of load: ranges
   vector reserved at half its real size (guaranteed realloc), function
   names formatted via printf `%T`, source file names re-converted per
   line-table entry, line vectors copied. Fixed all four with identical
   output. −2.7% min, −5.4% median (A/B).

5. **No per-line-entry file-name strings** (`beam_jit_common.*`,
   `beam_jit_metadata.cpp`). LineData now points into the per-module
   file-name cache; lines vectors exactly reserved. −1.9% min, −6.3%
   median (A/B).

6. **Unrolled MD5 transformation** (`erl_md5.c`). The module-MD5 used a
   rolled 64-iteration loop with per-round branches and table-loaded
   shifts; replaced with the standard unrolled RFC 1321 form. ~−1% load
   (MD5 is ~1.8% of the profile); erlang:md5 itself −22% per byte;
   digests verified unchanged.

   (Plus: lock-order registration for the new dirty locks, needed by
   debug/lcnt builds.)

## Rejected experiments (logged in LOG.md)

- Op-reader 1/2-byte fast path (regressed: code-layout sensitive).
- Batched atom insertion under one write lock (wash: lock overhead is not
  the dominant atom cost).
- asmjit CodeBuffer pre-reserve (wash-to-worse: asmjit growth policy fine).

## Correctness validation

- `bench/verify.escript`: loads all modules, executes a spread of
  functions/literals/exports, hashes all results — hash identical to the
  unpatched baseline after every kept patch (covers `module_info(md5)`).
- `bench/stress.escript`: reload, purge, delete + error_handler stubs,
  tracing on exports across reload, funs held across purge with all three
  code indices rotated, on_load success/failure, `code:atomic_load`,
  4-way concurrent loading. Passes on every kept patch.
- Full stress + verify under the `TYPE=debug FLAVOR=jit` emulator: all VM
  assertions, the staging full-scan equivalence checks, and the lock-order
  checker pass.
- kernel `code_SUITE`: **56 ok, 0 failed**, 1 skipped of 57 (skip = `big_boot_embedded` "Needs crypto!", environmental).

## What dominates the remaining time (future work)

Post-patch profile of `load`: asmjit `Assembler::_emit` ~14% (x86 encoder
proper), op decode ~4%, `beam_load_emit_op` operand massaging ~4%,
transform engine ~2.6%, atom-table hashing ~2.2%. Meaningful further wins
likely require either asmjit-level encoder work, reducing emitted
instruction counts, or parallelizing prepare_loading across schedulers —
all larger projects than single-night patches.

## Reproducing

```
bench/gen_modules.escript 100 100 bench/src   # generate sources
bin/erlc -o bench/ebin bench/src/*.erl        # compile
bench/bench.sh 15 load                        # benchmark
bin/escript bench/verify.escript bench/ebin   # correctness hash
bin/escript bench/stress.escript bench/ebin   # staging gauntlet
```
