#!/usr/bin/env bash
# Generate riscv-dv random programs for this core with the Python generator
# (pyflow), then build images and check them on Spike (scripts/riscvdv_prepare.py).
# Usage: scripts/riscvdv_gen.sh <tag> <instr_cnt> [iterations] [test]
#   tag        output directory under build/riscv-dv/
#   instr_cnt  replaces INSTR_CNT in compliance/riscv-dv/rv64im/testlist.yaml
#   iterations overrides the per-test iteration count (optional)
#   test       run only this test from the list (optional)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DV=${RISCV_DV:-$HOME/hwtools/riscv-dv}
TAG=$1; INSTR_CNT=$2; ITER=${3:-}; TEST=${4:-}
OUT=$ROOT/build/riscv-dv/$TAG
source "${DV_VENV:-$HOME/hwenv}/bin/activate"

# riscv-dv's pygen imports `imp`, which Python 3.12 removed. Apply the one-line
# fix kept in this repo unless it is already applied.
PATCH=$ROOT/compliance/riscv-dv/patches/0001-python312-importlib-reload.patch
if ! git -C "$DV" apply --reverse --check "$PATCH" 2>/dev/null; then
  git -C "$DV" apply "$PATCH"
fi
# pyflow imports the target by module name from pygen_src/target/<target>.
mkdir -p "$DV/pygen/pygen_src/target/rv64im"
cp "$ROOT/compliance/riscv-dv/rv64im/riscv_core_setting.py" "$DV/pygen/pygen_src/target/rv64im/"

rm -rf "$OUT"; mkdir -p "$OUT"
sed "s/INSTR_CNT/$INSTR_CNT/" "$ROOT/compliance/riscv-dv/rv64im/testlist.yaml" > "$OUT/testlist.yaml"
args=(--simulator pyflow --target rv64im --custom_target "$ROOT/compliance/riscv-dv/rv64im"
      --testlist "$OUT/testlist.yaml" --steps gen -o "$OUT" --isa rv64im --mabi lp64 --gen_timeout 600)
[[ -n $ITER ]] && args+=(--iterations "$ITER")
# One test per run.py call, so a generator failure is recorded for that test
# instead of stopping the others.
tests=${TEST:-$(sed -n 's/^- test: //p' "$OUT/testlist.yaml")}
for t in $tests; do
  if (cd "$DV" && python3 -W ignore::SyntaxWarning run.py "${args[@]}" --test "$t") >> "$OUT/gen.log" 2>&1; then
    echo "GEN_OK $t"
  else
    echo "GEN_FAIL $t (see build/riscv-dv/$TAG/gen.log)"
  fi
done
echo "GENERATED: $(ls "$OUT"/asm_test/*.S 2>/dev/null | wc -l) programs (instr_cnt=$INSTR_CNT) in build/riscv-dv/$TAG"

"${RV_PYTHON:-$HOME/.venvs/riscv-soc/bin/python}" "$ROOT/scripts/riscvdv_prepare.py" "$OUT"
