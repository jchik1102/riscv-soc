param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [switch]$Synthesize
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$linuxPathOutput = & wsl -d $Distro --exec wslpath -a $root
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
$linuxRoot = ($linuxPathOutput | Out-String).Trim()
function Python([string[]]$PythonArgs) {
    & wsl -d $Distro --cd $linuxRoot --exec $LinuxPython @PythonArgs
    if ($LASTEXITCODE -ne 0) { throw "WSL Python failed: $PythonArgs" }
}
Python @('scripts/gen_map.py', '--check')
Python @('scripts/programs.py')
Python @('-m', 'pytest', '-q')
& "$PSScriptRoot/qualify_xsim.ps1" -Vivado $Vivado
& "$PSScriptRoot/run_ram.ps1" -Vivado $Vivado
& "$PSScriptRoot/run_muldiv.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_muldiv_mutants.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_integration.ps1" -Vivado $Vivado
$groups = Get-Content -LiteralPath (Join-Path $root 'config/regression.json') -Raw | ConvertFrom-Json
$compiled = $false
foreach ($group in $groups) {
    $cases = if ($group.cases -is [string] -and $group.cases -eq 'all') { @() } else { @($group.cases) }
    foreach ($cycle in $group.reset_cycles) {
        $resetMode = if ($group.reset_mode) { $group.reset_mode } else { 0 }
        & "$PSScriptRoot/run_core.ps1" -Vivado $Vivado -SkipCompile:$compiled -MaxDelay $group.max_delay -Seed $group.seed -ResetCycle $cycle -ResetMode $resetMode -Cases $cases
        $compiled = $true
    }
}
Python @('scripts/check_all.py')
$pipeGroups = Get-Content -LiteralPath (Join-Path $root 'config/regression_pipeline.json') -Raw | ConvertFrom-Json
$compiled = $false
foreach ($group in $pipeGroups) {
    $cases = if ($group.cases -is [string] -and $group.cases -eq 'all') { @() } else { @($group.cases) }
    foreach ($cycle in $group.reset_cycles) {
        $resetMode = if ($group.reset_mode) { $group.reset_mode } else { 0 }
        $irq = if ($group.irq_rate) { $group.irq_rate } else { 0 }
        & "$PSScriptRoot/run_core.ps1" -Core pipeline -Vivado $Vivado -SkipCompile:$compiled -MaxDelay $group.max_delay -Seed $group.seed -ResetCycle $cycle -ResetMode $resetMode -IrqRate $irq -Cases $cases
        $compiled = $true
    }
}
Python @('scripts/check_all.py', '--core', 'pipeline')
Python @('scripts/compare_cores.py')
& "$PSScriptRoot/run_soc_s4.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_pipeline_mutants.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_sdram.ps1" -Vivado $Vivado
& "$PSScriptRoot/run_sdram_mutants.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_soc_s5.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_cache.ps1" -Vivado $Vivado
& "$PSScriptRoot/run_cache_mutants.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_soc_s6.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_accel.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_accel_mutants.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_soc_s7.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
& "$PSScriptRoot/run_soc_s8.ps1" -Vivado $Vivado -Distro $Distro -LinuxPython $LinuxPython
Python @('scripts/check_fault_injection.py')
Python @('scripts/spike_compare.py')
if ($Synthesize) { & "$PSScriptRoot/synthesize.ps1" -Quartus $Quartus }
Write-Host 'REGRESSION_PASS: model, fault injection, tool qualification, RAM, M unit and RTL mutants, integration (both cores), multicycle and pipeline CPU traces, core comparison, S4 SoC firmware, pipeline mutants, S5 SDRAM unit/tester/mutants/SoC, S6 cache unit/mutants/SoC, S7 accelerator unit/mutants/SoC, S8 demonstration and random whole-system SoC runs, GCC, Spike'
