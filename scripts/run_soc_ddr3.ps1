param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python'
)
# S6 SoC programs with DDR3 behind the SDRAM region (tb/ddr3/soc_ddr3_tb.sv):
# the pipeline SoC with caches, ddr3_bridge, the MIG's simulation build and
# Micron's DDR3 model, for the runs in config/soc_ddr3_runs.json; then
# scripts/check_soc_ddr3.py checks every transcript and compares it with the
# SDR SDRAM run (build/xsim_soc_s6/, from make test-sim). Needs the MIG from
# fpga/arty_a7/gen_mig.tcl in build/mig/ (scripts/run_ddr3.ps1 generates it).
# Logs in build/xsim_soc_ddr3/; prints DDR3_SOC_PASS.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_soc_ddr3'
New-Item -ItemType Directory -Force $out | Out-Null
$rtl = Join-Path $root 'build/mig/ip/mig_ddr3/mig_ddr3/user_design/rtl'
$model = Join-Path $root 'build/mig/example/mig_ddr3_ex/imports'
if (!(Test-Path (Join-Path $rtl 'mig_ddr3.v'))) { throw 'No MIG in build/mig: run scripts/run_ddr3.ps1 or fpga/arty_a7/gen_mig.tcl first' }
Push-Location $out
try {
    $migFiles = Get-ChildItem -Path $rtl -Recurse -Filter '*.v' | Where-Object { $_.Name -ne 'mig_ddr3_mig.v' } | ForEach-Object { $_.FullName }
    & (Join-Path $Vivado 'bin/xvlog.bat') @migFiles (Join-Path $Vivado 'data/verilog/src/glbl.v') | Out-File -Encoding ascii compile_mig.log
    if ($LASTEXITCODE -ne 0) { throw 'MIG compilation failed' }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv -i $model -d x2Gb -d sg15E -d x16 (Join-Path $model 'ddr3_model.sv') | Out-File -Encoding ascii compile_model.log
    if ($LASTEXITCODE -ne 0) { throw 'DDR3 model compilation failed' }
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv',
        'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv',
        'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv', 'rtl/soc/bus_arbiter.sv',
        'rtl/soc/bus_decoder.sv', 'rtl/soc/mmio_bus.sv', 'rtl/peripherals/uart.sv', 'rtl/peripherals/timer.sv',
        'rtl/peripherals/perf_counters.sv', 'rtl/peripherals/irq_ctrl.sv', 'rtl/peripherals/matrix_accel.sv',
        'rtl/peripherals/fir_filter.sv', 'rtl/memory/cache.sv', 'rtl/memory/cache_regs.sv', 'rtl/soc/burst_arbiter.sv',
        'rtl/memory/onchip_ram.sv', 'rtl/memory/async_fifo.sv', 'rtl/memory/ddr3_bridge.sv', 'rtl/soc/cpu_soc.sv',
        'tb/ddr3/soc_ddr3_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-File -Encoding ascii compile_soc.log
    if ($LASTEXITCODE -ne 0) { throw 'DDR3 SoC compilation failed (build/xsim_soc_ddr3/compile_soc.log)' }
    $runs = Get-Content -LiteralPath (Join-Path $root 'config/soc_ddr3_runs.json') -Raw | ConvertFrom-Json
    $elaborated = @{}
    foreach ($run in $runs) {
        $snapshot = "soc_ddr3_$($run.icache)_$($run.dcache)"
        if (!$elaborated.ContainsKey($snapshot)) {
            "soc_ddr3_tb glbl -s $snapshot --timescale 1ns/1ps -L unisims_ver -L secureip -generic_top ICACHE_BYTES=$($run.icache) -generic_top DCACHE_BYTES=$($run.dcache)" |
                Set-Content -LiteralPath "$snapshot.elab" -Encoding ascii
            & (Join-Path $Vivado 'bin/xelab.bat') -f "$snapshot.elab" | Out-File -Encoding ascii "elab_$snapshot.log"
            if ($LASTEXITCODE -ne 0) { throw "DDR3 SoC elaboration failed: $snapshot" }
            $elaborated[$snapshot] = $true
        }
        $image = (Join-Path $root $run.image).Replace('\', '/')
        $trace = (Join-Path $out "$($run.name).csv").Replace('\', '/')
        "$snapshot -runall -onerror quit -log $($run.name).log -testplusarg IMAGE=$image -testplusarg TRACE=$trace -testplusarg CACHE_EN=$($run.cache_en)" |
            Set-Content -LiteralPath "$($run.name).args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$($run.name).args" | Out-Null
        $log = Get-Content -LiteralPath "$($run.name).log" -Raw
        $pass = [regex]::Match($log, '(?m)^SOC_DDR3_TEST_PASS .*$').Value
        # The Micron model reports protocol and timing violations as "... ERROR: ...".
        if (!$pass -or $log -match '(?im)^\s*(Fatal|Error):' -or $log -cmatch 'ERROR') { throw "DDR3 SoC run failed: build/xsim_soc_ddr3/$($run.name).log" }
        Write-Host "$($run.name): $pass"
    }
} finally { Pop-Location }
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/check_soc_ddr3.py
if ($LASTEXITCODE -ne 0) { throw 'DDR3 SoC Python checks failed' }
Write-Host 'DDR3_SOC_PASS'
