param([string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado', [string]$Only = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_integration'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv','rtl/soc/soc_pkg.sv','rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv', 'rtl/core/load_store.sv', 'rtl/core/regfile.sv','rtl/core/mul_iter.sv','rtl/core/div_iter.sv','rtl/core/muldiv_unit.sv', 'rtl/core/csr_file.sv','rtl/core/core_multicycle.sv','rtl/core/core_pipeline.sv','rtl/soc/bus_arbiter.sv','rtl/soc/bus_decoder.sv','rtl/soc/mmio_bus.sv','rtl/peripherals/uart.sv','rtl/peripherals/timer.sv','rtl/peripherals/perf_counters.sv', 'rtl/peripherals/irq_ctrl.sv', 'rtl/peripherals/matrix_accel.sv', 'rtl/peripherals/fir_filter.sv', 'rtl/memory/cache.sv', 'rtl/memory/cache_regs.sv', 'rtl/soc/burst_arbiter.sv','rtl/memory/onchip_ram.sv','rtl/memory/sdram_ctrl.sv','rtl/memory/sdram_tester.sv','tb/unit/sdram_model.sv','tb/core/sdram_pll_sim.sv','rtl/soc/cpu_soc.sv','fpga/de10_lite/synthesis_top.sv','tb/core/soc_tb.sv','tb/core/fault_tb.sv','tb/core/soc_array_tb.sv','tb/core/soc_muldiv_tb.sv','tb/core/soc_fir_tb.sv','tb/core/soc_fir_hw_tb.sv','tb/core/pipe_fault_tb.sv','rtl/memory/boot_rom.sv','fpga/de10_lite/de10_lite_top.sv','tb/core/board_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'Integration compilation failed' }
    $expected = (Get-Content -LiteralPath (Join-Path $root 'build/firmware/fir_expected.json') -Raw | ConvertFrom-Json).checksum
    $expectedHex = '{0:x}' -f [uint64]$expected
    Copy-Item -LiteralPath (Join-Path $root 'build/firmware/fir_words.hex') -Destination (Join-Path $out 'fir_words.hex') -Force
    Copy-Item -LiteralPath (Join-Path $root 'build/firmware/s4_demo_words.hex') -Destination (Join-Path $out 's4_demo_words.hex') -Force
    Copy-Item -LiteralPath (Join-Path $root 'build/firmware/s5_sdram_words.hex') -Destination (Join-Path $out 's5_sdram_words.hex') -Force
    $s5Expected = '{0:x}' -f [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/s5_expected.json') -Raw | ConvertFrom-Json).checksum_31
    Copy-Item -LiteralPath (Join-Path $root 'build/firmware/s6_bench_words.hex') -Destination (Join-Path $out 's6_bench_words.hex') -Force
    $s6Expected = (& wsl -d Ubuntu --cd ((& wsl -d Ubuntu --exec wslpath -a $root) | Out-String).Trim() --exec /home/jonat/.venvs/riscv-soc/bin/python -c "from scripts.check_s6_bench import expected_results; print(format(expected_results('s6_bench')[1] & 0x7fffffff, 'x'))" | Out-String).Trim()
    Copy-Item -LiteralPath (Join-Path $root 'build/firmware/s7_bench_words.hex') -Destination (Join-Path $out 's7_bench_words.hex') -Force
    $s7Expected = (& wsl -d Ubuntu --cd ((& wsl -d Ubuntu --exec wslpath -a $root) | Out-String).Trim() --exec /home/jonat/.venvs/riscv-soc/bin/python -c "from scripts.check_s7_bench import expected_results; print(format(expected_results('s7_bench', 4)[1] & 0x7fffffff, 'x'))" | Out-String).Trim()
    Copy-Item -LiteralPath (Join-Path $root 'build/firmware/s8_bench_words.hex') -Destination (Join-Path $out 's8_bench_words.hex') -Force
    $s8Expected = (& wsl -d Ubuntu --cd ((& wsl -d Ubuntu --exec wslpath -a $root) | Out-String).Trim() --exec /home/jonat/.venvs/riscv-soc/bin/python -c "from scripts.check_s8_demo import expected_results; print(format(expected_results('s8_bench', 4)[2] & 0x7fffffff, 'x'))" | Out-String).Trim()
    $firCases = (Join-Path $root 'tests/fir/fir_soc.txt').Replace('\','/')
    $runs = @(@('soc_tb', 0), @('fault_tb', 0), @('soc_array_tb', 0), @('soc_muldiv_tb', 0), @('soc_fir_tb', 0),
              @('pipe_fault_tb', 1), @('soc_tb', 1), @('soc_array_tb', 1), @('soc_muldiv_tb', 1), @('soc_fir_tb', 1), @('soc_fir_hw_tb', 1), @('board_tb', 1), @('board_tb', 0), @('board_s4_tb', 1), @('board_s5_tb', 1), @('board_s6_tb', 1), @('board_s7_tb', 1), @('board_s8_tb', 1))
    foreach ($run in $runs) {
        $top, $pipeline = $run
        if ($Only -and $top -ne $Only) { continue }
        $snapshot = "${top}_p$pipeline"
        $generic = if ($top -like '*fault_tb') { @() } elseif ($top -eq 'soc_fir_hw_tb') { @('-generic_top', 'LANES=4') } else { @('-generic_top', "PIPELINE=$pipeline") }
        $unit = $top
        if ($top -eq 'board_s4_tb') { $unit = 'board_tb'; $generic += @('-generic_top', 'DEMO=1') }
        if ($top -eq 'board_s5_tb') { $unit = 'board_tb'; $generic += @('-generic_top', 'DEMO=2') }
        if ($top -eq 'board_s6_tb') { $unit = 'board_tb'; $generic += @('-generic_top', 'DEMO=3') }
        if ($top -eq 'board_s7_tb') { $unit = 'board_tb'; $generic += @('-generic_top', 'DEMO=4') }
        if ($top -eq 'board_s8_tb') { $unit = 'board_tb'; $generic += @('-generic_top', 'DEMO=5') }
        (@($unit, '-s', $snapshot, '--timescale', '1ns/1ps') + $generic) -join ' ' | Set-Content -LiteralPath "$snapshot.elab" -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f "$snapshot.elab"
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed: $snapshot" }
        $firmware = @{soc_muldiv_tb='muldiv'; soc_fir_tb='fir'; soc_fir_hw_tb='fir_hw'}[$top]
        if (!$firmware) { $firmware = 'array' }
        $image = (Join-Path $root "build/firmware/$firmware.hex").Replace('\','/')
        "$snapshot -runall -onerror quit -log $snapshot.log -testplusarg IMAGE=$image -testplusarg EXPECTED=$expectedHex -testplusarg S5_EXPECTED=$s5Expected -testplusarg S6_EXPECTED=$s6Expected -testplusarg S7_EXPECTED=$s7Expected -testplusarg S8_EXPECTED=$s8Expected -testplusarg CASES=$firCases" | Set-Content -LiteralPath "$snapshot.args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$snapshot.args"
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $snapshot" }
        $log = Get-Content -LiteralPath "$snapshot.log" -Raw
        $marker = @{soc_tb='SOC_TEST_PASS';fault_tb='FAULT_TEST_PASS';soc_array_tb='SOC_ARRAY_TEST_PASS';soc_muldiv_tb='SOC_MULDIV_TEST_PASS';soc_fir_tb='SOC_FIR_TEST_PASS';soc_fir_hw_tb='SOC_FIR_HW_TEST_PASS';pipe_fault_tb='PIPE_FAULT_TEST_PASS';board_tb='BOARD_TB_PASS';board_s4_tb='BOARD_TB_PASS: demo=1';board_s5_tb='BOARD_TB_PASS: demo=2';board_s6_tb='BOARD_TB_PASS: demo=3';board_s7_tb='BOARD_TB_PASS: demo=4';board_s8_tb='BOARD_TB_PASS: demo=5'}[$top]
        if ($log -notmatch $marker -or $log -match '(?im)^\s*(Fatal|Error):') { throw "Checks failed: $snapshot" }
    }
} finally { Pop-Location }
