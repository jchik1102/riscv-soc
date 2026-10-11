param([string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $Quartus 'bin64/quartus_sh.exe') -t (Join-Path $root 'fpga/de10_lite/ram_probe.tcl')
if ($LASTEXITCODE -ne 0) { throw "Quartus RAM probe failed: $LASTEXITCODE" }
