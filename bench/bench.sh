#!/usr/bin/env bash
# Benchmark module loading in the freshly built erts.
# Usage: bench/bench.sh [iterations] [mode]
#   mode = load (default) | prepare | finish
# Each iteration is a fresh VM; prints all samples plus min/median/mean.
set -euo pipefail

OTP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$OTP_ROOT/bench"
ITER="${1:-15}"
MODE="${2:-load}"
ERL="$OTP_ROOT/bin/erl"
ESCRIPT="$OTP_ROOT/bin/escript"

samples=()
for i in $(seq 1 "$ITER"); do
    us=$("$ESCRIPT" "$BENCH/load_bench.escript" "$BENCH/ebin" "$MODE")
    samples+=("$us")
done

printf '%s\n' "${samples[@]}" | sort -n | awk -v mode="$MODE" -v n="$ITER" '
    { a[NR] = $1; sum += $1 }
    END {
        min = a[1]
        med = (NR % 2) ? a[(NR+1)/2] : int((a[NR/2] + a[NR/2+1]) / 2)
        printf "mode=%s n=%d min=%d median=%d mean=%d max=%d (us)\n",
               mode, n, min, med, sum/NR, a[NR]
    }'
