param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [string[]]$Only = @()
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_soc_s6'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv',
        'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv',
        'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv', 'rtl/soc/bus_arbiter.sv',
        'rtl/soc/bus_decoder.sv', 'rtl/soc/mmio_bus.sv', 'rtl/peripherals/uart.sv', 'rtl/peripherals/timer.sv',
        'rtl/peripherals/perf_counters.sv', 'rtl/peripherals/irq_ctrl.sv', 'rtl/peripherals/matrix_accel.sv', 'rtl/memory/cache.sv', 'rtl/memory/cache_regs.sv', 'rtl/soc/burst_arbiter.sv',
        'rtl/memory/onchip_ram.sv', 'rtl/memory/sdram_ctrl.sv', 'rtl/soc/cpu_soc.sv',
        'tb/unit/sdram_model.sv', 'tb/core/soc_s6_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'S6 SoC compilation failed' }
    $runs = Get-Content -LiteralPath (Join-Path $root 'config/soc_s6_runs.json') -Raw | ConvertFrom-Json
    $elaborated = @{}
    foreach ($run in $runs) {
        if ($Only.Count -and $Only -notcontains $run.name) { continue }
        $snapshot = "soc_s6_$($run.icache)_$($run.dcache)"
        if (!$elaborated.ContainsKey($snapshot)) {
            "soc_s6_tb -s $snapshot --timescale 1ns/1ps -generic_top ICACHE_BYTES=$($run.icache) -generic_top DCACHE_BYTES=$($run.dcache)" |
                Set-Content -LiteralPath "$snapshot.elab" -Encoding ascii
            & (Join-Path $Vivado 'bin/xelab.bat') -f "$snapshot.elab"
            if ($LASTEXITCODE -ne 0) { throw "S6 SoC elaboration failed: $snapshot" }
            $elaborated[$snapshot] = $true
        }
        $image = (Join-Path $root $run.image).Replace('\', '/')
        $trace = (Join-Path $out "$($run.name).csv").Replace('\', '/')
        $reset = if ($null -ne $run.reset_at) { $run.reset_at } else { -1 }
        $fill = if ($run.reset_fill) { 1 } else { 0 }
        "$snapshot -runall -onerror quit -log $($run.name).log -testplusarg IMAGE=$image -testplusarg TRACE=$trace " +
            "-testplusarg CACHE_EN=$($run.cache_en) -testplusarg RESET_AT=$reset -testplusarg RESET_FILL=$fill" |
            Set-Content -LiteralPath "$($run.name).args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$($run.name).args"
        if ($LASTEXITCODE -ne 0) { throw "S6 SoC simulation failed: $($run.name)" }
        $log = Get-Content -LiteralPath "$($run.name).log" -Raw
        if ($log -notmatch 'SOC_S6_TEST_PASS' -or $log -match '(?im)^\s*(Fatal|Error):') { throw "S6 SoC checks failed: $($run.name)" }
    }
} finally { Pop-Location }
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
$checkArgs = @('scripts/check_soc_s6.py') + $Only
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython @checkArgs
if ($LASTEXITCODE -ne 0) { throw 'S6 SoC Python checks failed' }
