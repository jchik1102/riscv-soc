#!/usr/bin/env bash
# Show that the async_fifo proof (formal/async_fifo.sby) catches
# FIFO bugs: each mutant below must make the proof FAIL.
# Writes results/formal/cdc_fifo_mutants.txt; exits 1 if a mutant passes.
set -uo pipefail
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH=$HOME/oss-cad-suite/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/results/formal/cdc_fifo_mutants.txt
mkdir -p "$(dirname "$OUT")"; : > "$OUT"
status=0
# name | sed expression applied to rtl/async_fifo.sv
while IFS='|' read -r name expr; do
  w=$(mktemp -d)
  cp "$ROOT"/formal/async_fifo.sby "$ROOT"/formal/async_fifo_formal.sv "$ROOT"/rtl/memory/async_fifo.sv "$w"/
  sed -i 's|../rtl/memory/||' "$w/async_fifo.sby"
  sed -i "$expr" "$w/async_fifo.sv"
  if cmp -s "$ROOT/rtl/memory/async_fifo.sv" "$w/async_fifo.sv"; then
    result="NOT_APPLIED"; failed=""
  else
    (cd "$w" && timeout 900 sby -f async_fifo.sby prove < /dev/null > /dev/null 2>&1)
    result=$(cut -d' ' -f1 "$w/async_fifo_prove/status" 2>/dev/null || echo ERROR)
    failed=$(grep -oE 'failed assertion [^ ]+' "$w/async_fifo_prove/logfile.txt" 2>/dev/null | head -1)
  fi
  printf "%-22s %-11s %s\n" "$name" "$result" "$failed" | tee -a "$OUT"
  [[ $result == FAIL ]] || status=1
  rm -rf "$w"
done <<'LIST'
full_misses_lap|s/wire full = w_gray == {~r_sync2\[ADDR:ADDR-1\], r_sync2\[ADDR-2:0\]};/wire full = 1'b0;/
write_ignores_full|s/assign s_ready = !s_rst \&\& !full;/assign s_ready = !s_rst;/
read_ignores_ready|s/if (m_valid \&\& m_ready) begin/if (m_valid) begin/
empty_misses_data|s/wire empty = r_gray == w_sync2;/wire empty = 1'b0;/
LIST
exit $status
