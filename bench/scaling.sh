#!/usr/bin/env bash
cd /home/hugo/otp
m() { for i in $(seq 1 8); do ./bin/escript /tmp/lb_count.escript /home/hugo/otp/bench/ebin_scale $1; done | sort -n | head -1; }
for r in 1 2; do
  git checkout -q code-loading-opt && make emulator >/dev/null 2>&1
  echo "BRANCH r$r: N100=$(m 100) N200=$(m 200) N400=$(m 400)"
  git checkout -q master && make emulator >/dev/null 2>&1
  echo "MASTER r$r: N100=$(m 100) N200=$(m 200) N400=$(m 400)"
done
git checkout -q code-loading-opt && make emulator >/dev/null 2>&1
echo "DONE back on branch"
