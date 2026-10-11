param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string[]]$Cases = @(),
    [int]$Seed = 1,
    [int]$MaxDelay = 5,
    [int]$ResetCycle = -1,
    [int]$ResetMode = 0,
    [int]$IrqRate = 0,
    [ValidateSet('multicycle', 'pipeline')][string]$Core = 'multicycle',
    [switch]$SkipCompile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pipeline = $Core -eq 'pipeline'
$top = if ($pipeline) { 'pipe_tb' } else { 'core_tb' }
$out = Join-Path $root $(if ($pipeline) { 'build/xsim_pipe' } else { 'build/xsim_core' })
if ($Cases.Count -eq 0) { $Cases = Get-Content -LiteralPath (Join-Path $root 'build/programs/manifest.json') -Raw | ConvertFrom-Json }
New-Item -ItemType Directory -Force $out | Out-Null
function Invoke-Xilinx([string]$Tool, [string[]]$ToolArgs) {
    & (Join-Path $Vivado "bin/$Tool.bat") @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed: $LASTEXITCODE" }
}
Push-Location $out
try {
    if (!$SkipCompile) {
        $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv', 'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv', 'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv', "tb/core/$top.sv") | ForEach-Object { Join-Path $root $_ }
        Invoke-Xilinx 'xvlog' (@('--sv') + $sources)
        Invoke-Xilinx 'xelab' @($top, '-s', $top, '--timescale', '1ns/1ps', '--debug', 'typical')
    }
    foreach ($case in $Cases) {
        $name = "${case}_s${Seed}_d${MaxDelay}_r${ResetCycle}"
        if ($ResetMode -ne 0) { $name += "_m${ResetMode}" }
        if ($IrqRate -ne 0) { $name += "_i${IrqRate}" }
        $image = (Join-Path $root "build/programs/$case.hex").Replace('\', '/')
        $trace = (Join-Path $out "$name.csv").Replace('\', '/')
        if (!(Test-Path -LiteralPath $image)) { throw "Missing $image; run scripts/programs.py" }
        @($top, '-runall', '-onerror quit', "-log $name.log",
            "-testplusarg IMAGE=$image", "-testplusarg TRACE=$trace", "-testplusarg SEED=$Seed",
            "-testplusarg MAX_DELAY=$MaxDelay", "-testplusarg RESET_CYCLE=$ResetCycle", "-testplusarg RESET_MODE=$ResetMode", "-testplusarg IRQ_RATE=$IrqRate") |
            Set-Content -LiteralPath "$name.args" -Encoding ascii
        Invoke-Xilinx 'xsim' @('-f', "$name.args")
        $log = Get-Content -LiteralPath "$name.log" -Raw
        if ($log -notmatch 'CORE_TB_DONE' -or $log -match '(?im)^\s*(Fatal|Error):') { throw "Simulation failed: $name" }
        Write-Host "SIMULATED: $trace (run independent trace checker before accepting)"
    }
} finally { Pop-Location }
