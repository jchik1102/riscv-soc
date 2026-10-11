param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [int]$Transactions = 5000
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/accel_mutants.py
if ($LASTEXITCODE -ne 0) { throw 'Mutant generation failed' }
$base = Join-Path $root 'build/accel_mutants'
$mutants = Get-Content -LiteralPath (Join-Path $base 'mutants.json') -Raw | ConvertFrom-Json
$results = @()
foreach ($mutant in $mutants) {
    $name = $mutant.name
    $dir = Join-Path $base $name
    Push-Location $dir
    try {
        $sources = @((Join-Path $root 'rtl/soc/platform_pkg.sv'), (Join-Path $root 'rtl/soc/soc_pkg.sv'), (Join-Path $dir 'matrix_accel.sv'),
            (Join-Path $root 'tb/unit/accel_tb.sv'))
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not compile: $name" }
        "accel_tb -s accel_tb --timescale 1ns/1ps -generic_top N=$($mutant.n) -generic_top PARALLEL=$($mutant.parallel) -generic_top TRANSACTIONS=$Transactions" |
            Set-Content -LiteralPath 'mutant.elab' -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f 'mutant.elab' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Mutant did not elaborate: $name" }
        'accel_tb -runall -onerror quit -log mutant.log -testplusarg SEED=1 -testplusarg TRACE=mutant.csv' | Set-Content -LiteralPath 'mutant.args' -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f 'mutant.args' | Out-Null
        $log = Get-Content -LiteralPath 'mutant.log' -Raw
        $fatal = [regex]::Match($log, '(?m)^Fatal: .*$').Value
        $first = [regex]::Match($log, '(?m)^Error: .*$').Value
        $by = 'unit bench model'
        if ($log -match 'ACCEL_TEST_PASS' -and !$fatal) {
            & wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/check_accel_unit.py "build/accel_mutants/$name/mutant.csv" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { throw "Accelerator checks MISSED injected RTL defect: $name" }
            $by = 'transcript replay'; $first = 'model/accel_model.py replay failed'
        }
        $diagnostic = if ($first) { $first } else { $fatal }
        Write-Host "DETECTED ${name} ($by): $diagnostic"
        $results += [ordered]@{ mutant = $name; n = $mutant.n; parallel = $mutant.parallel; result = 'DETECTED'; by = $by; first_error = $first; fatal = $fatal }
    } finally { Pop-Location }
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'build/accel_mutants.json') -Encoding ascii
Write-Host "ACCEL_MUTANTS_PASS: checks detected $($results.Count) injected accelerator defects"
