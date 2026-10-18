param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Matlab = 'C:\Program Files\MATLAB\R2026a\bin\matlab.exe',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [int[]]$Lanes = @(1, 2, 4, 8, 16),
    [switch]$SkipMatlab,
    [switch]$SkipMutants
)
# Hardware FIR filter (rtl/peripherals/fir_filter.sv):
#   1. MATLAB (matlab/fir_vectors.m) regenerates the expected outputs with the
#      fixed-point model and they must equal the committed copies in tests/fir/
#      (skipped with -SkipMatlab, as the regression does);
#   2. tb/unit/fir_tb.sv runs the cases in tests/fir/fir_cases.txt for each
#      LANES value; every output must match MATLAB bit for bit;
#   3. tb/unit/fir_adc_tb.sv: the ADC model feeding the filter (two runs), then
#      matlab/adc_fir_check.m on their outputs (skipped with -SkipMatlab);
#   4. each mutant from scripts/fir_mutants.py must make the bench fail.
# Logs in build/xsim_fir/; prints FIR_UNIT_PASS, FIR_ADC_MATLAB_PASS and FIR_MUTANTS_PASS.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_fir'
New-Item -ItemType Directory -Force $out | Out-Null
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
$cases = (Join-Path $root 'tests/fir/fir_cases.txt').Replace('\', '/')

if (!$SkipMatlab) {
    & wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/fir_reference.py
    if ($LASTEXITCODE -ne 0) { throw 'FIR reference failed' }
    $matlabDir = (Join-Path $root 'matlab').Replace('\', '/')
    $vectors = (Join-Path $root 'build/fir').Replace('\', '/')
    & $Matlab -batch "addpath('$matlabDir'); fir_vectors('$vectors')"
    if ($LASTEXITCODE -ne 0) { throw 'MATLAB fir_vectors failed' }
    foreach ($f in @('fir_cases.txt', 'fir_soc.txt', 'lowpass.txt')) {
        $new = Get-Content -LiteralPath (Join-Path $root "build/fir/$f") -Raw
        $old = Get-Content -LiteralPath (Join-Path $root "tests/fir/$f") -Raw
        if ($new -ne $old) { throw "MATLAB output differs from tests/fir/${f}: copy build/fir/$f there if the change is intended" }
    }
    Write-Host 'FIR_MATLAB_VECTORS_MATCH: build/fir equals tests/fir'
}

function Run-Bench([string]$dir, [string]$filter, [int]$lanes, [string]$name) {
    Push-Location $dir
    try {
        $sources = @((Join-Path $root 'rtl/soc/platform_pkg.sv'), (Join-Path $root 'rtl/soc/soc_pkg.sv'), $filter,
            (Join-Path $root 'tb/unit/fir_tb.sv'))
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "FIR bench did not compile: $name" }
        "fir_tb -s $name --timescale 1ns/1ps -generic_top LANES=$lanes" | Set-Content -LiteralPath "$name.elab" -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f "$name.elab" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "FIR bench did not elaborate: $name" }
        "$name -runall -onerror quit -log $name.log -testplusarg CASES=$cases" | Set-Content -LiteralPath "$name.args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$name.args" | Out-Null
        return Get-Content -LiteralPath "$name.log" -Raw
    } finally { Pop-Location }
}

$filter = Join-Path $root 'rtl/peripherals/fir_filter.sv'
foreach ($l in $Lanes) {
    $log = Run-Bench $out $filter $l "fir_lanes$l"
    $pass = [regex]::Match($log, '(?m)^FIR_TB_PASS .*$').Value
    if (!$pass -or $log -match '(?im)^\s*(Fatal|Error):') { throw "FIR bench failed: build/xsim_fir/fir_lanes$l.log" }
    Write-Host $pass
}
Write-Host "FIR_UNIT_PASS: lanes $($Lanes -join ',') match MATLAB"

# The ADC model (tb/unit/adc_rnm.sv) feeding the filter, with the MATLAB
# low-pass coefficients: one tone with an ideal ADC, then two tones with a
# noisy ADC. MATLAB (matlab/adc_fir_check.m) checks the outputs bit for bit and
# measures SNR and the filter's attenuation.
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/peripherals/fir_filter.sv', 'tb/unit/adc_rnm.sv',
        'tb/unit/fir_adc_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ADC bench did not compile' }
    $coeffs = (Join-Path $root 'tests/fir/lowpass.txt').Replace('\', '/')
    foreach ($t in 0, 1) {
        $name = "fir_adc_test$t"
        "fir_adc_tb -s $name --timescale 1ns/1ps -generic_top TEST=$t" | Set-Content -LiteralPath "$name.elab" -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f "$name.elab" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ADC bench did not elaborate: $name" }
        $csv = (Join-Path $out "$name.csv").Replace('\', '/')
        "$name -runall -onerror quit -log $name.log -testplusarg COEFFS=$coeffs -testplusarg OUT=$csv" | Set-Content -LiteralPath "$name.args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$name.args" | Out-Null
        $log = Get-Content -LiteralPath "$name.log" -Raw
        $pass = [regex]::Match($log, '(?m)^FIR_ADC_TB_PASS .*$').Value
        if (!$pass -or $log -match '(?im)^\s*(Fatal|Error):') { throw "ADC bench failed: build/xsim_fir/$name.log" }
        Write-Host $pass
    }
} finally { Pop-Location }
if (!$SkipMatlab) {
    $matlabDir = (Join-Path $root 'matlab').Replace('\', '/')
    $o = $out.Replace('\', '/')
    & $Matlab -batch "addpath('$matlabDir'); adc_fir_check('$o/fir_adc_test0.csv', '$o/fir_adc_test1.csv', '$coeffs', '$o/adc_fir_check.log')"
    if ($LASTEXITCODE -ne 0) { throw 'MATLAB adc_fir_check failed' }
    Write-Host 'FIR_ADC_MATLAB_PASS'
}

if (!$SkipMutants) {
    & wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/fir_mutants.py
    if ($LASTEXITCODE -ne 0) { throw 'FIR mutant generation failed' }
    $base = Join-Path $root 'build/fir_mutants'
    $mutants = Get-Content -LiteralPath (Join-Path $base 'mutants.json') -Raw | ConvertFrom-Json
    $results = @()
    foreach ($m in $mutants) {
        $dir = Join-Path $base $m.name
        $log = Run-Bench $dir (Join-Path $dir 'fir_filter.sv') $m.lanes 'mutant'
        if ($log -match '(?m)^FIR_TB_PASS') { throw "FIR bench MISSED injected defect: $($m.name)" }
        $first = [regex]::Match($log, '(?m)^Error: .*$').Value
        if (!$first) { $first = [regex]::Match($log, '(?m)^Fatal: .*$').Value }
        Write-Host "DETECTED $($m.name): $first"
        $results += [ordered]@{ mutant = $m.name; lanes = $m.lanes; result = 'DETECTED'; first_error = $first }
    }
    $results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'build/fir_mutants.json') -Encoding ascii
    Write-Host "FIR_MUTANTS_PASS: the bench detected $($results.Count) of $($mutants.Count) injected defects"
}
