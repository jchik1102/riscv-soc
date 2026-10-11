param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [int]$Transactions = 1500
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/sdram_mutants.py
if ($LASTEXITCODE -ne 0) { throw 'Mutant generation failed' }
$base = Join-Path $root 'build/sdram_mutants'
$names = Get-Content -LiteralPath (Join-Path $base 'mutants.json') -Raw | ConvertFrom-Json
$results = @()
foreach ($name in $names) {
    $dir = Join-Path $base $name
    Push-Location $dir
    try {
        $sources = @((Join-Path $root 'rtl/soc/platform_pkg.sv'), (Join-Path $root 'rtl/soc/soc_pkg.sv'), (Join-Path $dir 'sdram_ctrl.sv'),
            (Join-Path $root 'tb/unit/sdram_model.sv'), (Join-Path $root 'tb/unit/sdram_tb.sv'))
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not compile: $name" }
        "sdram_tb -s sdram_tb --timescale 1ns/1ps -generic_top TRANSACTIONS=$Transactions" | Set-Content -LiteralPath 'mutant.elab' -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f 'mutant.elab' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not elaborate: $name" }
        'sdram_tb -runall -onerror quit -log mutant.log -testplusarg SEED=1' | Set-Content -LiteralPath 'mutant.args' -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f 'mutant.args' | Out-Null
        $log = Get-Content -LiteralPath 'mutant.log' -Raw
        $fatal = [regex]::Match($log, '(?m)^Fatal: .*$').Value
        $first = [regex]::Match($log, '(?m)^Error: .*$').Value
        if ($log -match 'SDRAM_TEST_PASS' -or !$fatal) { throw "SDRAM bench MISSED injected RTL defect: $name" }
        $diagnostic = if ($first) { $first } else { $fatal }
        Write-Host "DETECTED ${name}: $diagnostic"
        $results += [ordered]@{ mutant = $name; result = 'DETECTED'; first_error = $first; fatal = $fatal }
    } finally { Pop-Location }
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'build/sdram_mutants.json') -Encoding ascii
Write-Host "SDRAM_MUTANTS_PASS: unit bench detected $($results.Count) injected SDRAM controller defects"
