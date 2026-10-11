param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [int[]]$Seeds = @(1, 2)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_muldiv'
New-Item -ItemType Directory -Force $out | Out-Null
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'WSL access failed' }
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/muldiv_vectors.py
if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
Push-Location $out
try {
    $sources = @('rtl/core/core_pkg.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv', 'tb/unit/muldiv_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'M unit compilation failed' }
    & (Join-Path $Vivado 'bin/xelab.bat') muldiv_tb -s muldiv_tb --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'M unit elaboration failed' }
    $vectors = (Join-Path $root 'build/muldiv/vectors.txt').Replace('\', '/')
    foreach ($seed in $Seeds) {
        "muldiv_tb -runall -onerror quit -log muldiv_s$seed.log -testplusarg VECTORS=$vectors -testplusarg SEED=$seed" |
            Set-Content -LiteralPath "muldiv_s$seed.args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "muldiv_s$seed.args"
        if ($LASTEXITCODE -ne 0) { throw "M unit simulation failed: seed $seed" }
        $log = Get-Content -LiteralPath "muldiv_s$seed.log" -Raw
        if ($log -notmatch 'MULDIV_TEST_PASS' -or $log -match '(?im)^\s*(Fatal|Error):') { throw "M unit checks failed: seed $seed" }
    }
} finally { Pop-Location }
