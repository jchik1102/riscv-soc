param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Part = 'xc7a100tcsg324-1'
)
# Out-of-context Vivado implementation of fpga/de10_lite/synthesis_top.sv (the
# pipeline core, M unit, on-chip RAM, peripherals and the 4x4 accelerator; the
# same configuration as `make fpga-synth`) for a Xilinx Artix-7 at 50 MHz.
# Writes build/vivado/synthesis_top/ and prints VIVADO_PASS or VIVADO_FAIL.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = (Join-Path $root 'build/vivado/synthesis_top').Replace('\', '/')
New-Item -ItemType Directory -Force $out | Out-Null
$sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv',
    'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv',
    'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv', 'rtl/soc/bus_arbiter.sv', 'rtl/soc/bus_decoder.sv',
    'rtl/soc/mmio_bus.sv', 'rtl/peripherals/uart.sv', 'rtl/peripherals/timer.sv', 'rtl/peripherals/perf_counters.sv',
    'rtl/peripherals/irq_ctrl.sv', 'rtl/peripherals/matrix_accel.sv', 'rtl/memory/cache.sv', 'rtl/memory/cache_regs.sv',
    'rtl/soc/burst_arbiter.sv', 'rtl/memory/onchip_ram.sv', 'rtl/soc/cpu_soc.sv', 'fpga/de10_lite/synthesis_top.sv') |
    ForEach-Object { (Join-Path $root $_).Replace('\', '/') }
Push-Location $out
try {
    & (Join-Path $Vivado 'bin/vivado.bat') -mode batch -nojournal -log vivado.log -source ((Join-Path $root 'scripts/vivado-impl.tcl').Replace('\', '/')) `
        -tclargs synthesis_top $Part 20.0 $out 'PIPELINE:1+ACCEL_N:4' none @sources
    if ($LASTEXITCODE -ne 0) { throw "Vivado failed: $LASTEXITCODE" }
    Get-Content (Join-Path $out 'result.txt')
} finally { Pop-Location }
