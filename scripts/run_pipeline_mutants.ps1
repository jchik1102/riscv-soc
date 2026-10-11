param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/pipeline_mutants.py
if ($LASTEXITCODE -ne 0) { throw 'Mutant generation failed' }
$base = Join-Path $root 'build/pipeline_mutants'
$mutants = Get-Content -LiteralPath (Join-Path $base 'mutants.json') -Raw | ConvertFrom-Json
$runs = @(@('pipe_forward', 0, 0), @('pipe_random_3', 0, 0), @('pipe_random_17', 5, 0), @('control', 0, 0), @('memory_sizes', 5, 0),
          @('word_ops', 0, 0), @('alu64', 0, 0), @('m_mixed', 0, 0), @('pipe_kill_load', 0, 0), @('pipe_trap_shadow', 0, 0),
          @('s4_csr', 0, 0), @('s4_traps', 3, 0), @('s4_interrupt', 4, 40), @('pipe_random_3', 3, 40))
$results = @()
foreach ($property in $mutants.PSObject.Properties) {
    $name = $property.Name
    $dir = Join-Path $base $name
    Push-Location $dir
    try {
        $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv',
            'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv') | ForEach-Object { Join-Path $root $_ }
        $sources += @('alu.sv', 'load_store.sv', 'csr_file.sv', 'core_pipeline.sv') | ForEach-Object { Join-Path $dir $_ }
        $sources += Join-Path $root 'tb/core/pipe_tb.sv'
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not compile: $name" }
        & (Join-Path $Vivado 'bin/xelab.bat') pipe_tb -s pipe_tb --timescale 1ns/1ps | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not elaborate: $name" }
        $detected = $null
        foreach ($run in $runs) {
            $case, $delay, $irq = $run
            $image = (Join-Path $root "build/programs/$case.hex").Replace('\', '/')
            $trace = (Join-Path $dir "${case}_i$irq.csv").Replace('\', '/')
            @('pipe_tb', '-runall', '-onerror quit', "-log ${case}_i$irq.log", "-testplusarg IMAGE=$image", "-testplusarg TRACE=$trace",
              '-testplusarg SEED=1', "-testplusarg MAX_DELAY=$delay", '-testplusarg RESET_CYCLE=-1', '-testplusarg RESET_MODE=0', "-testplusarg IRQ_RATE=$irq") |
                Set-Content -LiteralPath "${case}_i$irq.args" -Encoding ascii
            & (Join-Path $Vivado 'bin/xsim.bat') -f "${case}_i$irq.args" | Out-Null
            $log = Get-Content -LiteralPath "${case}_i$irq.log" -Raw
            $fatal = [regex]::Match($log, '(?m)^Fatal: .*$').Value
            if ($fatal -or $log -notmatch 'CORE_TB_DONE') {
                $detected = "bench: $case d$delay i$irq $(if ($fatal) { $fatal } else { 'no completion' })"; break
            }
            $linuxTrace = ((& wsl -d $Distro --exec wslpath -a (Join-Path $dir "${case}_i$irq.csv")) | Out-String).Trim()
            $ErrorActionPreference = 'Continue'
            $check = & wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/check_pipeline_trace.py "build/programs/$case.hex" $linuxTrace 2>&1 | ForEach-Object { "$_" }
            $checkExit = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($checkExit -ne 0) {
                $line = ($check | Select-String -Pattern 'AssertionError' | Select-Object -Last 1).Line
                $detected = "checker: $case d$delay i$irq $line"; break
            }
        }
        if (!$detected) { throw "Pipeline checks MISSED injected RTL defect: $name" }
        Write-Host "DETECTED ${name}: $detected"
        $results += [ordered]@{ mutant = $name; category = $property.Value; result = 'DETECTED'; diagnostic = $detected }
    } finally { Pop-Location }
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'build/pipeline_mutants.json') -Encoding ascii
Write-Host "PIPELINE_MUTANTS_PASS: bench and checker detected $($results.Count) injected pipeline RTL defects"
