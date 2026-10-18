#!/usr/bin/env bash
# riscv-formal checks of the pipeline core (formal/rvfi/). Builds a riscv-formal
# tree under build/rvfi-<cfg> (its checks/ and insns/ plus this core as
# cores/riscv_soc), generates the checks from formal/rvfi/<cfg>.cfg, runs
# them, and writes results/riscv-formal/<cfg>.txt plus each check's log.
#   CFG=checks    (default) RV64I: every instruction, reg, pc, causal, unique, ill
#   CFG=checks_m  the 13 M instructions with ALTOPS, at depth MDEPTH (default 12)
# Needs riscv-formal (RVF, default ~/hwtools/riscv-formal) and OSS CAD Suite
# with the yosys-slang plugin. CHECKS="insn_add_ch0 reg_ch0" runs only those;
# RTL_ROOT points the checks at another copy of rtl/ and formal/ (mutants).
set -euo pipefail
cd "$(dirname "$0")/.."
RVF=${RVF:-$HOME/hwtools/riscv-formal}
CFG=${CFG:-checks}
MDEPTH=${MDEPTH:-12}
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH="$HOME/oss-cad-suite/bin:$PATH"
work=${WORK:-build/rvfi-$CFG}
core=$work/cores/riscv_soc
rm -rf "$work"; mkdir -p "$core"
cp -r "$RVF/checks" "$RVF/insns" "$work/"
sed -e "s#@ROOT@#${RTL_ROOT:-$PWD}#g" -e "s#@MDEPTH@#$MDEPTH#g" "formal/rvfi/$CFG.cfg" > "$core/checks.cfg"
(cd "$core" && python3 ../../checks/genchecks.py > genchecks.log)
if [[ -z ${CHECKS:-} ]]; then
  if [[ $CFG == checks_m ]]; then
    CHECKS=$(printf 'insn_%s_ch0 ' mul mulh mulhsu mulhu mulw div divu divuw divw rem remu remuw remw)
  else
    CHECKS=$(cd "$core/checks" && ls *.sby | sed 's/\.sby$//')
  fi
fi
make -C "$core/checks" -k -j"${JOBS:-$(nproc)}" $CHECKS > "$core/make.log" 2>&1 || true
[[ -n ${NO_SUMMARY:-} ]] && exit 0

out=results/riscv-formal
mkdir -p "$out/logs-$CFG"
summary=$out/$CFG.txt
{
  echo "riscv-formal $(git -C "$RVF" rev-parse --short HEAD), $(yosys -V | head -1)"
  echo "config: formal/rvfi/$CFG.cfg$([[ $CFG == checks_m ]] && echo ", insn depth $MDEPTH")"
  for c in $CHECKS; do
    status=$(cat "$core/checks/$c/status" 2>/dev/null || echo "NOT_RUN")
    secs=$(grep -oE "Elapsed clock time \[H:MM:SS \(secs\)\]: [0-9:]+ \([0-9]+\)" "$core/checks/$c/logfile.txt" 2>/dev/null | grep -oE "\([0-9]+\)" | tr -d '()' || true)
    printf '%-24s %-8s %6ss\n' "$c" "${status%% *}" "${secs:-?}"
    cp "$core/checks/$c/logfile.txt" "$out/logs-$CFG/$c.txt" 2>/dev/null || true
  done
} > "$summary"
pass=$(grep -c ' PASS ' "$summary" || true)
total=$(echo $CHECKS | wc -w)
echo "RISCV_FORMAL $CFG $pass of $total checks PASS" | tee -a "$summary"
[[ $pass -eq $total ]]
