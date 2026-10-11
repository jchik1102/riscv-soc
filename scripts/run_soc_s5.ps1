param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_soc_s5'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv',
        'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv',
        'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv', 'rtl/soc/bus_arbiter.sv',
        'rtl/soc/bus_decoder.sv', 'rtl/soc/mmio_bus.sv', 'rtl/peripherals/uart.sv', 'rtl/peripherals/timer.sv',
        'rtl/peripherals/perf_counters.sv', 'rtl/peripherals/irq_ctrl.sv', 'rtl/peripherals/matrix_accel.sv', 'rtl/memory/cache.sv', 'rtl/memory/cache_regs.sv', 'rtl/soc/burst_arbiter.sv', 'rtl/memory/onchip_ram.sv', 'rtl/memory/sdram_ctrl.sv', 'rtl/soc/cpu_soc.sv',
        'tb/unit/sdram_model.sv', 'tb/core/soc_s5_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'S5 SoC compilation failed' }
    & (Join-Path $Vivado 'bin/xelab.bat') soc_s5_tb -s soc_s5_tb --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'S5 SoC elaboration failed' }
    $runs = @()
    foreach ($name in (Get-Content -LiteralPath (Join-Path $root 'build/programs/manifest_s5.json') -Raw | ConvertFrom-Json)) {
        $runs += @{name = $name; image = "build/programs/$name.hex"; reset = -1}
    }
    $runs += @{name = 's5_sdram_fw'; image = 'build/firmware/s5_sdram.hex'; reset = -1}
    $runs += @{name = 's5_random_5_reset'; image = 'build/programs/s5_random_5.hex'; reset = 600}
    $runs += @{name = 's5_sdram_fw_reset'; image = 'build/firmware/s5_sdram.hex'; reset = 40000}
    foreach ($run in $runs) {
        $image = (Join-Path $root $run.image).Replace('\', '/')
        $trace = (Join-Path $out "$($run.name).csv").Replace('\', '/')
        "soc_s5_tb -runall -onerror quit -log $($run.name).log -testplusarg IMAGE=$image -testplusarg TRACE=$trace -testplusarg RESET_AT=$($run.reset)" |
            Set-Content -LiteralPath "$($run.name).args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$($run.name).args"
        if ($LASTEXITCODE -ne 0) { throw "S5 SoC simulation failed: $($run.name)" }
        $log = Get-Content -LiteralPath "$($run.name).log" -Raw
        if ($log -notmatch 'SOC_S5_TEST_PASS' -or $log -match '(?im)^\s*(Fatal|Error):') { throw "S5 SoC checks failed: $($run.name)" }
    }
} finally { Pop-Location }
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/check_soc_s5.py
if ($LASTEXITCODE -ne 0) { throw 'S5 SoC Python checks failed' }
