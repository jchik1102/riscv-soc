#!/usr/bin/env bash
# Build CoreMark for the pipeline core (tb/core/coremark_tb.sv).
#   bash scripts/coremark_build.sh [ITERATIONS]
# CoreMark itself is not vendored: it is cloned to ~/riscv-tools/coremark and
# must be at the commit below. The port is sw/coremark/. Writes
# build/coremark/coremark.{elf,dis,hex} and flags.txt.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CM=${COREMARK_DIR:-$HOME/riscv-tools/coremark}
COMMIT=1f483d5b8316753a742cbf5590caf5bd0a4e4777
ITERATIONS=${1:-10}
OUT=$ROOT/build/coremark
[[ -d $CM ]] || git clone -q https://github.com/eembc/coremark.git "$CM"
[[ $(git -C "$CM" rev-parse HEAD) == "$COMMIT" ]] || { echo "CoreMark at $CM is not commit $COMMIT"; exit 1; }
mkdir -p "$OUT"
FLAGS="-march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -O2"
cd "$ROOT"
riscv64-unknown-elf-gcc $FLAGS -ffreestanding -nostdlib -nostartfiles -Wl,--no-relax \
  -DPERFORMANCE_RUN=1 -DITERATIONS="$ITERATIONS" -DFLAGS_STR="\"$FLAGS\"" \
  -Isw/coremark -I"$CM" -T sw/coremark/link.ld \
  sw/coremark/start.S sw/coremark/core_portme.c sw/coremark/ee_printf.c \
  "$CM"/core_list_join.c "$CM"/core_main.c "$CM"/core_matrix.c "$CM"/core_state.c "$CM"/core_util.c \
  -lgcc -o "$OUT/coremark.elf"
riscv64-unknown-elf-objdump -d "$OUT/coremark.elf" > "$OUT/coremark.dis"
riscv64-unknown-elf-objcopy -O binary "$OUT/coremark.elf" "$OUT/coremark.bin"
python3 -c "import sys;d=open(sys.argv[1],'rb').read();open(sys.argv[2],'w').write('@00000000\n'+'\n'.join(f'{b:02x}' for b in d)+'\n')" \
  "$OUT/coremark.bin" "$OUT/coremark.hex"
{ echo "coremark $COMMIT"; echo "gcc $(riscv64-unknown-elf-gcc -dumpversion)"; echo "flags $FLAGS"; echo "iterations $ITERATIONS"; } > "$OUT/flags.txt"
echo "COREMARK_BUILT iterations=$ITERATIONS bytes=$(stat -c %s "$OUT/coremark.bin")"
