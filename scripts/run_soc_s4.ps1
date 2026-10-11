param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [string]$RxText = 'ping'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_soc_s4'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv',
        'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv',
        'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv', 'rtl/soc/bus_arbiter.sv',
        'rtl/soc/bus_decoder.sv', 'rtl/soc/mmio_bus.sv', 'rtl/peripherals/uart.sv', 'rtl/peripherals/timer.sv',
        'rtl/peripherals/perf_counters.sv', 'rtl/peripherals/irq_ctrl.sv', 'rtl/peripherals/matrix_accel.sv', 'rtl/memory/cache.sv', 'rtl/memory/cache_regs.sv', 'rtl/soc/burst_arbiter.sv', 'rtl/memory/onchip_ram.sv', 'rtl/soc/cpu_soc.sv', 'tb/core/soc_s4_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'S4 SoC compilation failed' }
    & (Join-Path $Vivado 'bin/xelab.bat') soc_s4_tb -s soc_s4_tb --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'S4 SoC elaboration failed' }
    $image = (Join-Path $root 'build/firmware/s4_demo.hex').Replace('\', '/')
    $trace = (Join-Path $out 's4_demo.csv').Replace('\', '/')
    "soc_s4_tb -runall -onerror quit -log s4_demo.log -testplusarg IMAGE=$image -testplusarg TRACE=$trace -testplusarg RX_TEXT=$RxText" |
        Set-Content -LiteralPath 's4_demo.args' -Encoding ascii
    & (Join-Path $Vivado 'bin/xsim.bat') -f 's4_demo.args'
    if ($LASTEXITCODE -ne 0) { throw 'S4 SoC simulation failed' }
    $log = Get-Content -LiteralPath 's4_demo.log' -Raw
    if ($log -notmatch 'SOC_S4_TEST_PASS' -or $log -match '(?im)^\s*(Fatal|Error):') { throw 'S4 SoC checks failed' }
} finally { Pop-Location }
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/check_soc_s4.py --rx $RxText
if ($LASTEXITCODE -ne 0) { throw 'S4 SoC Python checks failed' }
