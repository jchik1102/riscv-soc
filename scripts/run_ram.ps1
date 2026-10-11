param([string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_ram'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv','rtl/soc/soc_pkg.sv','rtl/memory/onchip_ram.sv','tb/unit/ram_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'RAM compilation failed' }
    & (Join-Path $Vivado 'bin/xelab.bat') ram_tb -s ram_tb --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'RAM elaboration failed' }
    & (Join-Path $Vivado 'bin/xsim.bat') ram_tb -runall -onerror quit -log ram.log
    if ($LASTEXITCODE -ne 0) { throw 'RAM simulation failed' }
    $log = Get-Content -LiteralPath ram.log -Raw
    if ($log -notmatch 'RAM_TEST_PASS' -or $log -match '(?im)^\s*(Fatal|Error):') { throw 'RAM checks failed' }
} finally { Pop-Location }
