#!/usr/bin/env bash
# riscv-formal against RTL mutants: the pipeline mutants of
# scripts/pipeline_mutants.py, plus two that only this flow uses (ADD computes
# SUB, and a wrong ALTOPS constant for MUL) to show the instruction checks are
# not vacuous. Each mutant runs all checks of formal/rvfi/checks.cfg in
# parallel (the MUL control runs insn_mul of checks_m.cfg at depth MDEPTH)
# and stops at its first failing check. Writes
# results/riscv-formal/mutants.txt and the failing check's log for each.
# MUTANTS="a b" runs only those. CFG=checks_m runs the 13 M instruction
# checks of checks_m.cfg instead (results/riscv-formal/mutants_m.txt), for
# mutants that checks.cfg, which excludes M instructions, cannot see.
set -euo pipefail
cd "$(dirname "$0")/.."
RVF=${RVF:-$HOME/hwtools/riscv-formal}
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH="$HOME/oss-cad-suite/bin:$PATH"
JOBS=${JOBS:-$(nproc)}
MDEPTH=${MDEPTH:-12}
CFG=${CFG:-checks}
MLIST=$(printf 'insn_%s_ch0 ' mul mulh mulhsu mulhu mulw div divu divuw divw rem remu remuw remw)
python3 scripts/pipeline_mutants.py > /dev/null
pipeline=$(python3 -c 'import json; print(" ".join(json.load(open("build/pipeline_mutants/mutants.json"))))')
names=${MUTANTS:-"add_computes_sub altops_mul_wrong $pipeline"}
out=results/riscv-formal
mkdir -p "$out/mutants"
summary=$out/mutants.txt
[[ $CFG == checks_m ]] && summary=$out/mutants_m.txt
echo "riscv-formal on RTL mutants (formal/rvfi/$CFG.cfg); each must fail a check" > "$summary"

kill_tree() { local c; for c in $(pgrep -P "$1" || true); do kill_tree "$c"; done; kill -TERM "$1" 2>/dev/null || true; }

for m in $names; do
  root=build/rvfi_mutants/$m
  rm -rf "$root"; mkdir -p "$root"
  cp -r rtl formal "$root/"
  case $m in
    add_computes_sub) python3 - "$root/rtl/core/alu.sv" "OP_ADD: result = a + b;" "OP_ADD: result = a - b;" ;;
    altops_mul_wrong) python3 - "$root/rtl/core/muldiv_unit.sv" "MD_MUL: r = (a + b) ^ 64'h2cdf52a55876063e;" "MD_MUL: r = (a + b) ^ 64'h2cdf52a55876063f;" ;;
    *) cp build/pipeline_mutants/"$m"/*.sv "$root/rtl/core/"; true ;;
  esac <<'EOF'
import sys
from pathlib import Path
path, old, new = sys.argv[1:4]
text = Path(path).read_text()
assert text.count(old) == 1, (path, old)
Path(path).write_text(text.replace(old, new))
EOF
  work=$root/rvfi; core=$work/cores/riscv_soc
  mkdir -p "$core"; cp -r "$RVF/checks" "$RVF/insns" "$work/"
  cfg=$CFG; list=""
  [[ $CFG == checks_m ]] && list=$MLIST
  [[ $m == altops_mul_wrong ]] && { cfg=checks_m; list=insn_mul_ch0; }
  sed -e "s#@ROOT@#$PWD/$root#g" -e "s#@MDEPTH@#$MDEPTH#g" "formal/rvfi/$cfg.cfg" > "$core/checks.cfg"
  (cd "$core" && python3 ../../checks/genchecks.py > genchecks.log)
  start=$(date +%s)
  make -C "$core/checks" -k -j"$JOBS" $list > "$core/make.log" 2>&1 &
  pid=$!
  failed=""
  while kill -0 "$pid" 2>/dev/null; do
    failed=$(grep -l FAIL "$core"/checks/*/status 2>/dev/null | head -1 || true)
    if [[ -n $failed ]]; then kill_tree "$pid"; break; fi
    sleep 5
  done
  wait "$pid" 2>/dev/null || true
  [[ -n $failed ]] || failed=$(grep -l FAIL "$core"/checks/*/status 2>/dev/null | head -1 || true)
  secs=$(( $(date +%s) - start ))
  if [[ -n $failed ]]; then
    check=$(basename "$(dirname "$failed")")
    cp "$core/checks/$check/logfile.txt" "$out/mutants/$m$([[ $CFG == checks_m ]] && echo _m).txt"
    echo "DETECTED $m by $check in ${secs}s"
  else
    echo "MISSED $m (all checks pass, ${secs}s)"
  fi | tee -a "$summary"
done
detected=$(grep -c '^DETECTED' "$summary" || true)
echo "RISCV_FORMAL_MUTANTS detected $detected of $(echo $names | wc -w)" | tee -a "$summary"
