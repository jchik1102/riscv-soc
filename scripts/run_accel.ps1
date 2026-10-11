param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [int[]]$Seeds = @(1, 2, 3),
    [int]$Transactions = 20000,
    [switch]$SkipCompile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_accel'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
$traces = @()
try {
    if (!$SkipCompile) {
        $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/peripherals/matrix_accel.sv', 'tb/unit/accel_tb.sv') | ForEach-Object { Join-Path $root $_ }
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
        if ($LASTEXITCODE -ne 0) { throw 'Accelerator compilation failed' }
    }
    foreach ($config in @(@(4, 1), @(2, 1), @(4, 0), @(2, 0))) {
        $n = $config[0]; $parallel = $config[1]
        $name = "accel_n${n}_p$parallel"
        "accel_tb -s $name --timescale 1ns/1ps -generic_top N=$n -generic_top PARALLEL=$parallel -generic_top TRANSACTIONS=$Transactions" |
            Set-Content -LiteralPath "$name.elab" -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f "$name.elab"
        if ($LASTEXITCODE -ne 0) { throw "Accelerator elaboration failed: $name" }
        $runSeeds = if ($n -eq 4 -and $parallel -eq 1) { $Seeds } else { @($Seeds[0]) }
        foreach ($seed in $runSeeds) {
            $log = "${name}_seed$seed.log"
            $trace = "${name}_seed$seed.csv"
            "$name -runall -onerror quit -log $log -testplusarg SEED=$seed -testplusarg TRACE=$trace" | Set-Content -LiteralPath "$name.args" -Encoding ascii
            & (Join-Path $Vivado 'bin/xsim.bat') -f "$name.args"
            if ($LASTEXITCODE -ne 0) { throw "Accelerator simulation failed: $log" }
            $text = Get-Content -LiteralPath $log -Raw
            if ($text -notmatch 'ACCEL_TEST_PASS' -or $text -match '(?im)^\s*(Fatal|Error):') { throw "Accelerator checks failed: $log" }
            $traces += "build/xsim_accel/$trace"
        }
    }
} finally { Pop-Location }
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/check_accel_unit.py @traces
if ($LASTEXITCODE -ne 0) { throw 'Accelerator transcript replay failed' }
Write-Host 'ACCEL_UNIT_PASS'
