# Overnight optimization plan — erts code loading

Branch: `code-loading-opt`. User is asleep; run autonomously, recover from
interruptions by re-reading this file + LOG.md and continuing.

## Protocol (per experiment)

1. Implement ONE change (working tree, uncommitted).
2. `make emulator` (~2.5 s incremental).
3. Sanity: `bin/escript bench/verify.escript bench/ebin` must print `OK <hash>`
   with the SAME hash as baseline (recorded below).
4. Measure: `bench/bench.sh 15 load` and `bench/bench.sh 15 prepare`.
5. Decide on **min** values vs current best baseline:
   - keep if load-min improves >1.5% (beyond noise) and verify passes
   - revert (`git checkout -- <files>`) otherwise
6. If kept: `git add -A && git commit` (one commit per experiment, message
   `loader-opt: <what> (<old> -> <new> us)`), and the new numbers become the
   reference baseline.
7. Append an entry to bench/LOG.md either way (hypothesis, diff summary,
   numbers, decision).
8. Occasionally re-run baseline on the last-kept commit to detect drift.

## Verify baseline

`verify.escript` hash (must match after every patch): see LOG.md baseline entry.

## Status (updated as the night went on)

DONE — kept: E2 staging sync, E7 fragment lookups, E8 rawLabels vector,
E9+E10 metadata registration, E11 MD5 unroll. Reverted: E1 reader fast
path, E3 atom batch, E6 buffer reserve. See LOG.md + REPORT.md.
Remaining below queue items E4(=done as E11)/E5 evaluated or skipped as
sub-threshold; kernel code_SUITE validation in progress.

## Experiment queue (priority order; update as results come in)

- [ ] E1 (pipeline validation, cheap): op reader fast path — inline/branch-hint
      the 1-byte case of beamreader_read_tagged in beam_file.c (~6% self time
      in beamcodereader_read_next path).
- [ ] E2 (big): incremental staged-table sync in erl_code_staged.h
      start_staging — tables are append-only and prefix-consistent, so sync
      only entries [dst->entries .. src->entries) instead of scanning all
      entries every finish_loading (export_start_staging alone is 3.2% of
      load; ~2M wasted iterations per 100 loads). MUST first read export.c
      OBJECT_STAGE macro: staged dispatch addresses may need refreshing for
      OLD entries too — check how addresses propagate across code indices
      (export_staged_stage / erts_export_put / commit). If old entries need
      address refresh, design dirty-tracking instead (loader knows which
      exports it touched).
- [ ] E3: atom chunk batch insert — amortize atom-table rwlock + double
      lookup across the per-module atom loop (erts_atom_put 4%).
- [ ] E4: MD5 (erl_md5.c hash_part 3.8% self) — faster MD5 round
      implementation (it is the RFC-1321-style reference); keep identical
      digests (verify covers module_info(md5) indirectly? add explicit check).
- [ ] E5: literal decode into a single heap fragment (two-pass sizing) to
      kill per-literal fragment allocs + cheapen erts_move_multi_frags.
- [ ] E6: asmjit CodeHolder/section buffer pre-reserve sized from BEAM code
      size (avoid grow/copy cycles); check bind_label/new_fixup costs.
- [ ] E7 (stretch): reduce per-module finish cost further (code barrier /
      thread-progress waits between sequential loads).

## Current status

See LOG.md — last entry is the source of truth for the current reference
numbers and which experiments are done.
