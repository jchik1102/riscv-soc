param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$image = (Join-Path $root 'build/firmware/s5_board_words.hex').Replace('\', '/')
$expected = [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/s5_expected.json') -Raw | ConvertFrom-Json).checksum_31
& (Join-Path $Quartus 'bin64/quartus_sh.exe') -t (Join-Path $root 'fpga/de10_lite/board.tcl') s5sim 1 $image 512 ([string]$expected) 2 8192
if ($LASTEXITCODE -ne 0) { throw 'Quartus compile (s5sim) failed' }
Push-Location (Join-Path $root 'build/quartus_board_s5sim_p1')
try {
    & (Join-Path $Quartus 'bin64/quartus_eda.exe') de10_lite_s5sim_p1 -c de10_lite_s5sim_p1 --simulation --tool=modelsim --format=verilog
    if ($LASTEXITCODE -ne 0) { throw 'Netlist writer failed' }
} finally { Pop-Location }
$out = Join-Path $root 'build/xsim_netlist'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    $lib = Join-Path $Quartus 'eda/sim_lib'
    & (Join-Path $Vivado 'bin/xvlog.bat') (Join-Path $lib 'fiftyfivenm_atoms.v') (Join-Path $lib 'altera_primitives.v') `
        (Join-Path $root 'build/quartus_board_s5sim_p1/simulation/questa/de10_lite_s5sim_p1.vo')
    if ($LASTEXITCODE -ne 0) { throw 'Netlist compilation failed' }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv (Join-Path $root 'tb/core/max10_encrypted_stubs.v') (Join-Path $root 'tb/unit/sdram_model.sv') `
        (Join-Path $root 'tb/core/board_netlist_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw 'Bench compilation failed' }
    & (Join-Path $Vivado 'bin/xelab.bat') board_netlist_tb -s netlist --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'Netlist elaboration failed' }
    & (Join-Path $Vivado 'bin/xsim.bat') netlist -runall -onerror quit -log netlist.log
    if ($LASTEXITCODE -ne 0) { throw 'Netlist simulation failed' }
    $log = Get-Content -LiteralPath netlist.log -Raw
    if ($log -notmatch 'NETLIST_TEST_PASS' -or $log -match '(?im)^\s*(Fatal|Error):') { throw 'Netlist checks failed' }
    Write-Host 'NETLIST_S5_PASS'
} finally { Pop-Location }
