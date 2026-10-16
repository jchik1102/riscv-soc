#!/usr/bin/env bash
# Build the riscv-arch-test (ACT4) self-checking ELFs for this core's
# configuration (compliance/act4/riscv-soc-rv64im), then convert each ELF to
# the byte-per-line hex image that tb/core/pipe_tb.sv loads.
# Expected values come from the Sail reference model at build time.
# Usage: scripts/act_build.sh [EXTENSIONS]   (default: I,M)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACT=${ACT_DIR:-$HOME/hwtools/riscv-arch-test}
EXTENSIONS=${1:-I,M}
CONFIG=$ROOT/compliance/act4/riscv-soc-rv64im/test_config.yaml
WORK=$ROOT/build/act4

source "${ACT_VENV:-$HOME/.venvs/act4}/bin/activate"
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$HOME/riscv-tools/sail-0.15/bin:$PATH"
"$HOME/riscv-tools/gcc-nightly-2026.08.27/bin/riscv64-unknown-elf-gcc" --version | head -1
sail_riscv_sim --version

make -C "$ACT" CONFIG_FILES="$CONFIG" EXTENSIONS="$EXTENSIONS" WORKDIR="$WORK"

# Convert every DUT ELF into a hex image and record its tohost address.
python3 "$ROOT/scripts/act_images.py" "$WORK"
