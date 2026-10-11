param([string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus', [string]$Stage = 's3', [int]$Pipeline = 1,
      [ValidateSet('fir', 's4', 's5', 's6', 's7', 's8')][string]$Demo = 'fir', [switch]$Power,
      [string]$Distro = 'Ubuntu', [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$image = Join-Path $root @{fir = 'build/firmware/fir_words.hex'; s4 = 'build/firmware/s4_board_words.hex'; s5 = 'build/firmware/s5_board_words.hex'; s6 = 'build/firmware/s6_board_words.hex'; s7 = 'build/firmware/s7_board_words.hex'; s8 = 'build/firmware/s8_board_words.hex'}[$Demo]
if (!(Test-Path -LiteralPath $image)) { throw 'Run scripts/programs.py first' }
$words = (Get-Content -LiteralPath $image).Count
if ($Demo -eq 'fir') {
    $expected = [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/fir_expected.json') -Raw | ConvertFrom-Json).checksum
    $demoId = 0
} elseif ($Demo -eq 's4') {
    $expected = [uint64]50
    $demoId = 1
} elseif ($Demo -eq 's8') {
    $expected = [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/s8_expected.json') -Raw | ConvertFrom-Json).checksum_31
    $demoId = 5
} elseif ($Demo -eq 's7') {
    $expected = [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/s7_expected.json') -Raw | ConvertFrom-Json).checksum_31
    $demoId = 4
} elseif ($Demo -eq 's6') {
    $expected = [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/s6_expected.json') -Raw | ConvertFrom-Json).checksum_31
    $demoId = 3
} else {
    $expected = [uint64](Get-Content -LiteralPath (Join-Path $root 'build/firmware/s5_expected.json') -Raw | ConvertFrom-Json).checksum_31
    $demoId = 2
}
if ($expected -ge 2147483648) { throw 'Expected value exceeds the 31-bit range verified for Quartus decimal parameters' }
& (Join-Path $Quartus 'bin64/quartus_sh.exe') -t (Join-Path $root 'fpga/de10_lite/board.tcl') $Stage $Pipeline $image.Replace('\', '/') $words ([string]$expected) $demoId
if ($LASTEXITCODE -ne 0) { throw "Quartus board compile failed: $LASTEXITCODE" }
if ($Power) {
    $name = "de10_lite_${Stage}_p$Pipeline"
    Push-Location (Join-Path $root "build/quartus_board_${Stage}_p$Pipeline")
    try {
        & (Join-Path $Quartus 'bin64/quartus_pow.exe') --read_settings_files=on --write_settings_files=off $name -c $name
        if ($LASTEXITCODE -ne 0) { throw "Quartus Power Analyzer failed: $LASTEXITCODE" }
    } finally { Pop-Location }
    Write-Host "POWER_ESTIMATE_DONE: build/quartus_board_${Stage}_p$Pipeline/output_files/$name.pow.summary (vectorless estimate, not a measurement)"
}
