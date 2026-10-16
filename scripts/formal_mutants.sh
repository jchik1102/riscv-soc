#!/usr/bin/env bash
# Run the muldiv formal tasks (formal/muldiv.sby, all 13 operations) against
# each M-unit RTL mutant made by scripts/muldiv_mutants.py (build/muldiv_mutants,
# created by `make test`). A mutant is DETECTED if any task fails (status FAIL);
# any other status (timeout, tool error) is reported as ERROR.
# Runs with K=4 free operand bits (muldiv_formal.sv) to keep the sweep short;
# `make formal` uses the default K.
# Writes results/formal/mutants.txt.
set -uo pipefail
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH=$HOME/oss-cad-suite/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MUT=$ROOT/build/muldiv_mutants
OUT=$ROOT/results/formal
TASKS="mul mulh mulhsu mulhu div divu rem remu mulw divw divuw remw remuw"
[[ -d $MUT ]] || { echo "no $MUT; run make test first"; exit 1; }
mkdir -p "$OUT"
: > "$OUT/mutants.txt"
work=$(mktemp -d)
for dir in "$MUT"/*/; do
  name=$(basename "$dir")
  w=$work/$name; mkdir -p "$w"
  cp "$ROOT"/formal/muldiv.sby "$ROOT"/formal/muldiv_formal.sv "$w"/
  cp "$ROOT"/rtl/soc/platform_pkg.sv "$ROOT"/rtl/soc/soc_pkg.sv "$ROOT"/rtl/core/core_pkg.sv \
     "$ROOT"/rtl/core/mul_iter.sv "$ROOT"/rtl/core/div_iter.sv "$ROOT"/rtl/core/muldiv_unit.sv "$w"/
  cp "$dir"/*.sv "$w"/                       # the mutated files replace the originals
  sed -i 's|\.\./rtl/soc/||; s|\.\./rtl/core/||; s| --top muldiv_formal| -G K=4 --top muldiv_formal|' "$w/muldiv.sby"
  # One sby call for all tasks: parallel sby calls on one file race on its
  # status database.
  (cd "$w" && timeout 3600 sby -f -j 13 muldiv.sby $TASKS < /dev/null > /dev/null 2>&1)
  res=$(for t in $TASKS; do echo "$t $(cut -d' ' -f1 "$w/muldiv_$t/status" 2>/dev/null || echo NONE)"; done)
  failed=$(echo "$res" | awk '$2=="FAIL"{print $1}' | tr '\n' ' ')
  other=$(echo "$res" | awk '$2!="FAIL" && $2!="PASS"{print $1"="$2}' | tr '\n' ' ')
  if [[ -n $other ]]; then verdict="ERROR: $other"
  elif [[ -n $failed ]]; then verdict="DETECTED by: $failed"
  else verdict="not detected"; fi
  printf "%-36s %s\n" "$name" "$verdict" | tee -a "$OUT/mutants.txt"
done
rm -rf "$work"
