param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/muldiv_mutants.py
if ($LASTEXITCODE -ne 0) { throw 'Mutant generation failed' }
$base = Join-Path $root 'build/muldiv_mutants'
$vectors = (Join-Path $root 'build/muldiv/vectors.txt').Replace('\', '/')
if (!(Test-Path -LiteralPath (Join-Path $root 'build/muldiv/vectors.txt'))) { throw 'Run scripts/run_muldiv.ps1 first' }
$names = Get-Content -LiteralPath (Join-Path $base 'mutants.json') -Raw | ConvertFrom-Json
$results = @()
foreach ($name in $names) {
    $dir = Join-Path $base $name
    Push-Location $dir
    try {
        $sources = @('core_pkg.sv', 'mul_iter.sv', 'div_iter.sv', 'muldiv_unit.sv') | ForEach-Object { Join-Path $dir $_ }
        $sources += Join-Path $root 'tb/unit/muldiv_tb.sv'
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not compile: $name" }
        & (Join-Path $Vivado 'bin/xelab.bat') muldiv_tb -s muldiv_tb --timescale 1ns/1ps | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not elaborate: $name" }
        "muldiv_tb -runall -onerror quit -log mutant.log -testplusarg VECTORS=$vectors -testplusarg SEED=1" |
            Set-Content -LiteralPath 'mutant.args' -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f 'mutant.args' | Out-Null
        $log = Get-Content -LiteralPath 'mutant.log' -Raw
        $fatal = [regex]::Match($log, '(?m)^Fatal: .*$').Value
        if ($log -match 'MULDIV_TEST_PASS' -or !$fatal) { throw "Unit bench MISSED injected RTL defect: $name" }
        Write-Host "DETECTED ${name}: $fatal"
        $results += [ordered]@{ mutant = $name; result = 'DETECTED'; diagnostic = $fatal }
    } finally { Pop-Location }
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'build/muldiv_mutants.json') -Encoding ascii
Write-Host "MULDIV_MUTANTS_PASS: unit bench detected $($results.Count) injected RTL defects"
