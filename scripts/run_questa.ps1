# The directed and self-checking benches run in a second simulator: Questa Intel
# Starter FPGA Edition. Same sources, generics, plusargs and pass markers as the
# XSim scripts (run_ram, run_muldiv, run_cache, run_sdram, run_accel, run_fir,
# run_core and run_integration); the CPU traces go through the same Python
# reference checker. The UVM bench is not here: the Starter licence has no
# SystemVerilog verification feature, so Questa refuses randomize() and
# covergroups (vsim-1), which tb/uvm uses.
#
# Logs in build/questa/<group>/; a one-line verdict per run in
# build/questa/summary.txt. -Only picks groups: units, cores, integration.
param(
    [string]$Questa = 'C:\intelFPGA_lite\24.1std\questa_fse',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [string[]]$Only = @('units', 'cores', 'integration')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $Questa 'win64'
$base = Join-Path $root 'build/questa'
New-Item -ItemType Directory -Force $base | Out-Null
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$summary = Join-Path $base 'summary.txt'
if (!(Test-Path $summary)) { New-Item -ItemType File $summary | Out-Null }

function Python([string[]]$PythonArgs) {
    & wsl -d $Distro --cd $linuxRoot --exec $LinuxPython @PythonArgs
    if ($LASTEXITCODE -ne 0) { throw "WSL Python failed: $PythonArgs" }
}
function Tool([string]$Name, [string[]]$ToolArgs, [string]$Log) {
    $ErrorActionPreference = 'Continue'   # stderr lines are not failures; the exit code is
    & (Join-Path $bin "$Name.exe") @ToolArgs 2>&1 | Out-File -Encoding utf8 $Log
    if ($LASTEXITCODE -ne 0) { throw "$Name failed ($LASTEXITCODE), see $Log" }
}
# vsim's exit code is not the verdict; the log is checked. Questa's transcript
# (-l) starts every line with "# "; the bench output is also written without it
# to <log> (the name the checkers read), the transcript kept as <log>.questa.
function Sim([string[]]$SimArgs, [string]$Console) {
    $ErrorActionPreference = 'Continue'
    $i = [array]::IndexOf($SimArgs, '-l')
    $log = $SimArgs[$i + 1]
    $SimArgs[$i + 1] = "$log.questa"
    & (Join-Path $bin 'vsim.exe') @SimArgs 2>&1 | Out-File -Encoding utf8 $Console
    if (Test-Path -LiteralPath "$log.questa") {
        Get-Content -LiteralPath "$log.questa" | ForEach-Object { $_ -replace '^# ?', '' } | Set-Content -LiteralPath $log -Encoding ascii
    } else { Set-Content -LiteralPath $log 'NO_TRANSCRIPT' }
}
# Fresh work library in $dir with the given sources.
function Compile([string]$dir, [string[]]$relative) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir
    try {
        if (Test-Path work) { Remove-Item -Recurse -Force work }
        Tool vlib @('work') 'vlib.log'
        Tool vlog (@('-sv', '-timescale', '1ns/1ps') + ($relative | ForEach-Object { Join-Path $root $_ })) 'compile.log'
    } finally { Pop-Location }
}
# Optimize $top with generics into snapshot $snap, run it, check the log.
function Run([string]$dir, [string]$top, [string]$snap, [string[]]$generics, [string[]]$plusargs, [string]$log, [string]$marker) {
    Push-Location $dir
    try {
        $g = @($generics | Where-Object { $_ } | ForEach-Object { "-G$_" })
        Tool vopt (@($top, '-o', "${snap}_opt") + $g) "$snap.vopt.log"
        $p = @($plusargs | Where-Object { $_ } | ForEach-Object { "+$_" })
        Sim (@('-c', "${snap}_opt", '-l', $log) + $p + @('-do', 'run -all; quit -f')) "$log.console"
        $text = Get-Content -LiteralPath $log -Raw
        $ok = $text -match [regex]::Escape($marker) -and $text -notmatch '(?m)^\*\*\s*(Error|Fatal)' -and $text -notmatch '(?im)^\s*(Fatal|Error):'
        $line = '{0,-44} {1}' -f ((Split-Path $dir -Leaf) + '/' + $log), $(if ($ok) { 'PASS' } else { 'FAIL' })
        Add-Content -LiteralPath $summary $line
        Write-Host $line
        if (!$ok) { throw "Questa run failed: $dir/$log" }
        return $text
    } finally { Pop-Location }
}
function Path([string]$p) { (Join-Path $root $p).Replace('\', '/') }
$pkgs = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv')

if ($Only -contains 'units') {
    $d = Join-Path $base 'units'
    Compile $d ($pkgs + @('rtl/memory/onchip_ram.sv', 'tb/unit/ram_tb.sv'))
    Run $d 'ram_tb' 'ram' @() @() 'ram.log' 'RAM_TEST_PASS' | Out-Null

    Python @('scripts/muldiv_vectors.py')
    Compile $d @('rtl/core/core_pkg.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv', 'tb/unit/muldiv_tb.sv')
    foreach ($seed in 1, 2) {
        Run $d 'muldiv_tb' 'muldiv' @() @("VECTORS=$(Path 'build/muldiv/vectors.txt')", "SEED=$seed") "muldiv_s$seed.log" 'MULDIV_TEST_PASS' | Out-Null
    }

    Compile $d ($pkgs + @('rtl/memory/cache.sv', 'tb/unit/cache_tb.sv'))
    foreach ($bytes in 2048, 4096) {
        foreach ($seed in $(if ($bytes -eq 2048) { 1, 2, 3 } else { 1 })) {
            Run $d 'cache_tb' "cache_$bytes" @("BYTES=$bytes", 'TRANSACTIONS=20000') @("SEED=$seed") "cache_${bytes}_seed$seed.log" 'CACHE_TEST_PASS' | Out-Null
        }
    }

    Compile $d ($pkgs + @('rtl/memory/sdram_ctrl.sv', 'rtl/memory/sdram_tester.sv', 'tb/unit/sdram_model.sv', 'tb/unit/sdram_tb.sv', 'tb/unit/sdram_tester_tb.sv'))
    foreach ($clk in 20000, 10000) {
        $name = if ($clk -eq 20000) { 'sdram_50' } else { 'sdram_100' }
        foreach ($seed in $(if ($clk -eq 20000) { 1, 2, 3 } else { 1 })) {
            Run $d 'sdram_tb' $name @("CLK_PS=$clk", 'TRANSACTIONS=6000') @("SEED=$seed") "${name}_seed$seed.log" 'SDRAM_TEST_PASS' | Out-Null
        }
    }
    Run $d 'sdram_tester_tb' 'sdram_tester' @() @() 'sdram_tester.log' 'SDRAM_TESTER_TEST_PASS' | Out-Null

    Compile $d ($pkgs + @('rtl/peripherals/matrix_accel.sv', 'tb/unit/accel_tb.sv'))
    $traces = @()
    foreach ($c in @(@(4, 1), @(2, 1), @(4, 0), @(2, 0))) {
        $n, $par = $c
        $name = "accel_n${n}_p$par"
        foreach ($seed in $(if ($n -eq 4 -and $par -eq 1) { 1, 2, 3 } else { 1 })) {
            Run $d 'accel_tb' $name @("N=$n", "PARALLEL=$par", 'TRANSACTIONS=20000') @("SEED=$seed", "TRACE=${name}_seed$seed.csv") "${name}_seed$seed.log" 'ACCEL_TEST_PASS' | Out-Null
            $traces += "build/questa/units/${name}_seed$seed.csv"
        }
    }
    Python (@('scripts/check_accel_unit.py') + $traces)
    Add-Content -LiteralPath $summary ('{0,-44} {1}' -f 'units/accel transcripts replayed in Python', 'PASS')

    Compile $d ($pkgs + @('rtl/peripherals/fir_filter.sv', 'tb/unit/fir_tb.sv'))
    foreach ($l in 1, 2, 4, 8, 16) {
        Run $d 'fir_tb' "fir_lanes$l" @("LANES=$l") @("CASES=$(Path 'tests/fir/fir_cases.txt')") "fir_lanes$l.log" 'FIR_TB_PASS' | Out-Null
    }
    Compile $d ($pkgs + @('rtl/peripherals/fir_filter.sv', 'tb/unit/adc_rnm.sv', 'tb/unit/fir_adc_tb.sv'))
    foreach ($t in 0, 1) {
        $csv = (Join-Path $d "fir_adc_test$t.csv").Replace('\', '/')
        Run $d 'fir_adc_tb' "fir_adc_test$t" @("TEST=$t") @("COEFFS=$(Path 'tests/fir/lowpass.txt')", "OUT=$csv") "fir_adc_test$t.log" 'FIR_ADC_TB_PASS' | Out-Null
    }
}

if ($Only -contains 'cores') {
    $core = @('rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv', 'rtl/core/load_store.sv', 'rtl/core/regfile.sv',
        'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv', 'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv')
    $all = Get-Content -LiteralPath (Join-Path $root 'build/programs/manifest.json') -Raw | ConvertFrom-Json
    foreach ($kind in 'multicycle', 'pipeline') {
        $top = if ($kind -eq 'pipeline') { 'pipe_tb' } else { 'core_tb' }
        $d = Join-Path $base $(if ($kind -eq 'pipeline') { 'pipe' } else { 'core' })
        Compile $d ($pkgs + $core + @("tb/core/$top.sv"))
        $matrix = if ($kind -eq 'pipeline') { 'config/regression_pipeline.json' } else { 'config/regression.json' }
        $first = $true
        foreach ($group in (Get-Content -LiteralPath (Join-Path $root $matrix) -Raw | ConvertFrom-Json)) {
            $cases = if ($group.cases -is [string] -and $group.cases -eq 'all') { $all } else { @($group.cases) }
            $mode = if ($group.reset_mode) { $group.reset_mode } else { 0 }
            $irq = if ($group.irq_rate) { $group.irq_rate } else { 0 }
            foreach ($cycle in $group.reset_cycles) {
                foreach ($case in $cases) {
                    $name = "${case}_s$($group.seed)_d$($group.max_delay)_r$cycle"
                    if ($mode -ne 0) { $name += "_m$mode" }
                    if ($irq -ne 0) { $name += "_i$irq" }
                    $plus = @("IMAGE=$(Path "build/programs/$case.hex")", "TRACE=$((Join-Path $d "$name.csv").Replace('\', '/'))", "SEED=$($group.seed)",
                        "MAX_DELAY=$($group.max_delay)", "RESET_CYCLE=$cycle", "RESET_MODE=$mode", "IRQ_RATE=$irq")
                    # One optimized snapshot per core; vopt again only for the first run.
                    if ($first) { Run $d $top $top @() $plus "$name.log" 'CORE_TB_DONE' | Out-Null; $first = $false }
                    else {
                        Push-Location $d
                        try {
                            Sim (@('-c', "${top}_opt", '-l', "$name.log") + ($plus | ForEach-Object { "+$_" }) + @('-do', 'run -all; quit -f')) "$name.log.console"
                            $text = Get-Content -LiteralPath "$name.log" -Raw
                            if ($text -notmatch 'CORE_TB_DONE' -or $text -match '(?m)^\*\*\s*(Error|Fatal)') { Add-Content $summary "$kind/$name FAIL"; throw "Questa run failed: $d/$name.log" }
                        } finally { Pop-Location }
                    }
                }
            }
        }
        $rel = "build/questa/$(Split-Path $d -Leaf)"
        Python @('scripts/check_all.py', '--directory', $rel, '--core', $kind) | Tee-Object -FilePath (Join-Path $d 'check_all.txt')
        $verdict = (Get-Content (Join-Path $d 'check_all.txt') | Select-String '^PASS: ' | Select-Object -Last 1).Line
        Add-Content -LiteralPath $summary ('{0,-44} {1}' -f "$kind traces checked against the reference model", $verdict)
    }
}

if ($Only -contains 'integration') {
    $d = Join-Path $base 'integration'
    $sources = $pkgs + @('rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv', 'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv',
        'rtl/core/muldiv_unit.sv', 'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv', 'rtl/soc/bus_arbiter.sv', 'rtl/soc/bus_decoder.sv', 'rtl/soc/mmio_bus.sv',
        'rtl/peripherals/uart.sv', 'rtl/peripherals/timer.sv', 'rtl/peripherals/perf_counters.sv', 'rtl/peripherals/irq_ctrl.sv', 'rtl/peripherals/matrix_accel.sv', 'rtl/peripherals/fir_filter.sv',
        'rtl/memory/cache.sv', 'rtl/memory/cache_regs.sv', 'rtl/soc/burst_arbiter.sv', 'rtl/memory/onchip_ram.sv', 'rtl/memory/sdram_ctrl.sv', 'rtl/memory/sdram_tester.sv', 'tb/unit/sdram_model.sv',
        'tb/core/sdram_pll_sim.sv', 'rtl/soc/cpu_soc.sv', 'fpga/de10_lite/synthesis_top.sv', 'tb/core/soc_tb.sv', 'tb/core/fault_tb.sv', 'tb/core/soc_array_tb.sv', 'tb/core/soc_muldiv_tb.sv',
        'tb/core/soc_fir_tb.sv', 'tb/core/soc_fir_hw_tb.sv', 'tb/core/pipe_fault_tb.sv', 'rtl/memory/boot_rom.sv', 'fpga/de10_lite/de10_lite_top.sv', 'tb/core/board_tb.sv')
    Compile $d $sources
    foreach ($f in 'fir_words.hex', 's4_demo_words.hex', 's5_sdram_words.hex', 's6_bench_words.hex', 's7_bench_words.hex', 's8_bench_words.hex') {
        Copy-Item -LiteralPath (Join-Path $root "build/firmware/$f") -Destination (Join-Path $d $f) -Force
    }
    $expected = '{0:x}' -f [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/fir_expected.json') -Raw | ConvertFrom-Json).checksum
    $s5 = '{0:x}' -f [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/s5_expected.json') -Raw | ConvertFrom-Json).checksum_31
    $py = { param($code) (& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython -c $code | Out-String).Trim() }
    $s6 = & $py "from scripts.check_s6_bench import expected_results; print(format(expected_results('s6_bench')[1] & 0x7fffffff, 'x'))"
    $s7 = & $py "from scripts.check_s7_bench import expected_results; print(format(expected_results('s7_bench', 4)[1] & 0x7fffffff, 'x'))"
    $s8 = & $py "from scripts.check_s8_demo import expected_results; print(format(expected_results('s8_bench', 4)[2] & 0x7fffffff, 'x'))"
    $markers = @{soc_tb = 'SOC_TEST_PASS'; fault_tb = 'FAULT_TEST_PASS'; soc_array_tb = 'SOC_ARRAY_TEST_PASS'; soc_muldiv_tb = 'SOC_MULDIV_TEST_PASS'; soc_fir_tb = 'SOC_FIR_TEST_PASS';
        soc_fir_hw_tb = 'SOC_FIR_HW_TEST_PASS'; pipe_fault_tb = 'PIPE_FAULT_TEST_PASS'; board_tb = 'BOARD_TB_PASS'; board_s4_tb = 'BOARD_TB_PASS: demo=1'; board_s5_tb = 'BOARD_TB_PASS: demo=2';
        board_s6_tb = 'BOARD_TB_PASS: demo=3'; board_s7_tb = 'BOARD_TB_PASS: demo=4'; board_s8_tb = 'BOARD_TB_PASS: demo=5'}
    $runs = @(@('soc_tb', 0), @('fault_tb', 0), @('soc_array_tb', 0), @('soc_muldiv_tb', 0), @('soc_fir_tb', 0),
        @('pipe_fault_tb', 1), @('soc_tb', 1), @('soc_array_tb', 1), @('soc_muldiv_tb', 1), @('soc_fir_tb', 1), @('soc_fir_hw_tb', 1), @('board_tb', 1), @('board_tb', 0),
        @('board_s4_tb', 1), @('board_s5_tb', 1), @('board_s6_tb', 1), @('board_s7_tb', 1), @('board_s8_tb', 1))
    foreach ($r in $runs) {
        $top, $pipeline = $r
        $snap = "${top}_p$pipeline"
        $unit = $top
        $generics = @(if ($top -like '*fault_tb') { @() } elseif ($top -eq 'soc_fir_hw_tb') { @('LANES=4') } else { @("PIPELINE=$pipeline") })
        if ($top -match '^board_s(\d)_tb$') { $unit = 'board_tb'; $generics += "DEMO=$([int]$Matches[1] - 3)" }
        $firmware = @{soc_muldiv_tb = 'muldiv'; soc_fir_tb = 'fir'; soc_fir_hw_tb = 'fir_hw'}[$top]
        if (!$firmware) { $firmware = 'array' }
        $plus = @("IMAGE=$(Path "build/firmware/$firmware.hex")", "EXPECTED=$expected", "S5_EXPECTED=$s5", "S6_EXPECTED=$s6", "S7_EXPECTED=$s7", "S8_EXPECTED=$s8",
            "CASES=$(Path 'tests/fir/fir_soc.txt')")
        Run $d $unit $snap $generics $plus "$snap.log" $markers[$top] | Out-Null
    }
}
Write-Host "QUESTA_DONE: $($Only -join ', ')"
