param([string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus', [string]$Stage = 's2', [int]$Pipeline = 0, [int]$AccelN = 0)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $Quartus 'bin64/quartus_sh.exe') -t (Join-Path $root 'fpga/de10_lite/synthesize.tcl') $Stage $Pipeline $AccelN
if ($LASTEXITCODE -ne 0) { throw "Quartus synthesis failed: $LASTEXITCODE" }
