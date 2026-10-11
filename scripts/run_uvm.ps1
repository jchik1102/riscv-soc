param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [ValidateSet('pipeline', 'multicycle')][string]$Core = 'pipeline',
    [ValidateSet('cpu_random_test', 'cpu_image_test')][string]$Test = 'cpu_random_test',
    [int]$Seed = 1,
    [int]$MaxDelay = 5,
    [int]$Programs = 10,
    [string[]]$Cases = @(),
    [int]$ResetAfter = -1,
    [switch]$AlwaysReady,
    [switch]$SkipCompile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root "build/uvm_$Core"
New-Item -ItemType Directory -Force $build | Out-Null
$savedVivadoEnv = $env:XILINX_VIVADO
$env:XILINX_VIVADO = $Vivado
function Invoke-Xilinx([string]$Tool, [string[]]$ToolArgs) {
    & (Join-Path $Vivado "bin/$Tool.bat") @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed: $LASTEXITCODE" }
}
Push-Location $build
try {
    if (!$SkipCompile) {
        $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv',
            'rtl/core/alu.sv', 'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv',
            'rtl/core/muldiv_unit.sv', 'rtl/core/csr_file.sv', 'rtl/core/core_multicycle.sv', 'rtl/core/core_pipeline.sv',
            'tb/uvm/cpu_if.sv', 'tb/uvm/cpu_uvm_pkg.sv', 'tb/uvm/cpu_uvm_tb.sv') | ForEach-Object { Join-Path $root $_ }
        $define = if ($Core -eq 'multicycle') { @('-d', 'MULTICYCLE') } else { @() }
        Invoke-Xilinx 'xvlog' (@('--sv', '-L', 'uvm') + $define + $sources)
        Invoke-Xilinx 'xelab' @('cpu_uvm_tb', '-L', 'uvm', '-s', 'cpu_uvm', '--timescale', '1ns/1ps')
    }
    $runs = if ($Test -eq 'cpu_image_test') { $Cases } else { @("random") }
    foreach ($case in $runs) {
        $name = if ($Test -eq 'cpu_image_test') { "${case}_s${Seed}_d${MaxDelay}_r${ResetAfter}" } else { "random_s${Seed}_d${MaxDelay}_p${Programs}" }
        if ($AlwaysReady) { $name += '_ready' }
        $out = Join-Path $build $name
        New-Item -ItemType Directory -Force $out | Out-Null
        $outArg = $out.Replace('\', '/')
        $simArgs = @('cpu_uvm', '-runall', '-onerror quit', "-log $name.log", "-sv_seed $Seed", "-cov_db_name $name",
            "-testplusarg UVM_TESTNAME=$Test", "-testplusarg MAX_DELAY=$MaxDelay", "-testplusarg OUT=$outArg",
            "-testplusarg PROGRAMS=$Programs", "-testplusarg UVM_VERBOSITY=UVM_LOW")
        if ($AlwaysReady) { $simArgs += '-testplusarg ALWAYS_READY' }
        if ($Test -eq 'cpu_image_test') {
            $image = (Join-Path $root "build/programs/$case.hex").Replace('\', '/')
            $simArgs += @("-testplusarg IMAGE=$image", "-testplusarg NAME=$case", "-testplusarg RESET_AFTER=$ResetAfter")
        }
        $simArgs | Set-Content -LiteralPath "$name.args" -Encoding ascii
        Invoke-Xilinx 'xsim' @('-f', "$name.args")
        $log = Get-Content -LiteralPath "$name.log" -Raw
        if ($log -notmatch 'UVM_CPU_TEST_PASS' -or $log -notmatch 'UVM_ERROR\s*:\s*0' -or $log -notmatch 'UVM_FATAL\s*:\s*0' -or
            $log -match '(?im)^\s*(Fatal|Error):') { throw "UVM run failed: $name" }
        Write-Host "UVM_RUN_PASS: $name"
    }
} finally { Pop-Location; $env:XILINX_VIVADO = $savedVivadoEnv }
