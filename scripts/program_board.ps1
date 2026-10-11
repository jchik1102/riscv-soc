param([string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus', [string]$Stage = 's3', [int]$Pipeline = 1,
      [string]$Cable = 'USB-Blaster [USB-0]')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sof = Join-Path $root "build/quartus_board_${Stage}_p$Pipeline/output_files/de10_lite_${Stage}_p$Pipeline.sof"
if (!(Test-Path -LiteralPath $sof)) { throw "Missing $sof; run scripts/build_board.ps1" }
& (Join-Path $Quartus 'bin64/quartus_pgm.exe') -l
& (Join-Path $Quartus 'bin64/quartus_pgm.exe') -c $Cable -a
if ($LASTEXITCODE -ne 0) { throw 'JTAG auto-detect failed; is the DE10-Lite connected and powered?' }
& (Join-Path $Quartus 'bin64/quartus_pgm.exe') -c $Cable -m JTAG -o "p;$sof"
if ($LASTEXITCODE -ne 0) { throw "Programming failed: $LASTEXITCODE" }
Write-Host "PROGRAMMED: $sof (observe LEDR/HEX on the board before claiming execution)"
