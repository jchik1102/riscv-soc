#!/usr/bin/env bash
# Verilator lint (-Wall) of the synthesizable RTL: the S8 SoC configuration
# with the pipeline core, caches, the 4x4 accelerator and the FIR filter, then
# the same SoC with the multicycle core, and the SDRAM controller, the SDRAM
# tester and the DDR3 bridge as their own tops (they sit beside cpu_soc in the
# board tops). Warnings listed with a reason in scripts/lint_waivers.vlt are
# accepted; any other warning or error fails. Two rules are off for every
# file: UNUSEDPARAM (the generated address-map package declares constants not
# every top uses) and UNUSEDSIGNAL (unused bits of a wider bus or struct, such
# as the upper address bits a peripheral ignores). Output in results/lint/.
set -uo pipefail
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH=$HOME/oss-cad-suite/bin:$PATH
cd "$(dirname "$0")/.."
OUT=results/lint
mkdir -p "$OUT"
verilator --version > "$OUT/version.txt"
PKG="rtl/soc/platform_pkg.sv rtl/soc/soc_pkg.sv rtl/core/core_pkg.sv"
SOC="$PKG rtl/core/decoder.sv rtl/core/alu.sv rtl/core/load_store.sv rtl/core/regfile.sv rtl/core/mul_iter.sv
  rtl/core/div_iter.sv rtl/core/muldiv_unit.sv rtl/core/csr_file.sv rtl/core/core_multicycle.sv
  rtl/core/core_pipeline.sv rtl/soc/bus_arbiter.sv rtl/soc/bus_decoder.sv rtl/soc/mmio_bus.sv rtl/peripherals/uart.sv
  rtl/peripherals/timer.sv rtl/peripherals/perf_counters.sv rtl/peripherals/irq_ctrl.sv rtl/peripherals/matrix_accel.sv
  rtl/peripherals/fir_filter.sv rtl/memory/cache.sv rtl/memory/cache_regs.sv rtl/soc/burst_arbiter.sv rtl/memory/onchip_ram.sv
  rtl/soc/cpu_soc.sv"
status=0
run() {   # run <name> <top> <files...> [-G options are part of the list]
  local name=$1 top=$2; shift 2
  local log=$OUT/$name.txt
  verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --top-module "$top" scripts/lint_waivers.vlt "$@" > "$log" 2>&1
  local count
  count=$(grep -cE '^%(Warning|Error)' "$log")
  echo "LINT $name: $count warnings or errors outside the waivers" | tee -a "$log"
  [[ $count -eq 0 ]] || status=1
}
run soc_pipeline cpu_soc -GPIPELINE=1 -GSDRAM=1 -GCACHE=1 -GACCEL_N=4 -GFIR_LANES=4 $SOC
run soc_multicycle cpu_soc -GPIPELINE=0 -GSDRAM=1 -GCACHE=1 -GACCEL_N=4 -GFIR_LANES=4 $SOC
run sdram_ctrl sdram_ctrl $PKG rtl/memory/sdram_ctrl.sv
run sdram_tester sdram_tester $PKG rtl/memory/sdram_tester.sv
run ddr3_bridge ddr3_bridge $PKG rtl/memory/async_fifo.sv rtl/memory/ddr3_bridge.sv
[[ $status -eq 0 ]] && echo "LINT_PASS" || echo "LINT_FAIL"
exit $status
