param([string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/qualification'
$savedVivadoEnv = $env:XILINX_VIVADO
$env:XILINX_VIVADO = $Vivado
New-Item -ItemType Directory -Force $out | Out-Null
function Run([string]$Tool, [string[]]$ToolArgs) {
    & (Join-Path $Vivado "bin/$Tool.bat") @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed: $LASTEXITCODE" }
}
Push-Location $out
try {
    Run 'xvlog' @('--sv', '-L', 'uvm', (Join-Path $root 'sim/cpu_sim/cpu_sim.srcs/sources_1/new/smoke-tb.sv'))
    Run 'xelab' @('smoke_tb', '-L', 'uvm', '-s', 'smoke', '--timescale', '1ns/1ps')
    Run 'xsim' @('smoke', '-runall', '-log', 'uvm_smoke.log')
    $smoke = Get-Content -LiteralPath uvm_smoke.log -Raw
    if ($smoke -notmatch 'PASS: UVM' -or $smoke -notmatch 'UVM_ERROR\s*:\s*0' -or $smoke -notmatch 'UVM_FATAL\s*:\s*0') { throw 'UVM qualification failed' }
    Run 'xcrg' @('-cov_db_dir', '.', '-cov_db_name', 'smoke', '-report_dir', 'coverage', '-report_format', 'all')
    if (!(Test-Path -LiteralPath coverage)) { throw 'No coverage report exported' }
    Run 'xvlog' @('--sv', '--work', 'assertion_lib', (Join-Path $root 'tb/unit/assertion_tb.sv'))
    Run 'xelab' @('assertion_lib.assertion_tb', '-s', 'assertions', '--timescale', '1ns/1ps')
    Run 'xsim' @('assertions', '-runall', '-log', 'assertion_pass.log')
    if ((Get-Content -LiteralPath assertion_pass.log -Raw) -notmatch 'ASSERTION_TEST_PASS') { throw 'Passing assertion not observed' }
    & (Join-Path $Vivado 'bin/xsim.bat') assertions -runall -onerror quit -testplusarg INJECT_FAILURE -log assertion_fail.log
    $failure = Get-Content -LiteralPath assertion_fail.log -Raw
    if ($failure -notmatch 'Fatal: EXPECTED_ASSERTION_FAILURE' -or $failure -match 'ASSERTION_TEST_PASS') { throw 'Injected assertion failure was not detected' }
    Write-Host 'QUALIFICATION_PASS: UVM, constrained randomization, coverage export, assertion pass and deliberate failure'
} finally { Pop-Location; $env:XILINX_VIVADO = $savedVivadoEnv }
