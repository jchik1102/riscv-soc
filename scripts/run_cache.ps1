param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [int[]]$Seeds = @(1, 2, 3),
    [int]$Transactions = 20000,
    [switch]$SkipCompile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_cache'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    if (!$SkipCompile) {
        $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/memory/cache.sv', 'tb/unit/cache_tb.sv') | ForEach-Object { Join-Path $root $_ }
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
        if ($LASTEXITCODE -ne 0) { throw 'Cache compilation failed' }
    }
    foreach ($bytes in @(2048, 4096)) {
        $name = "cache_$bytes"
        "cache_tb -s $name --timescale 1ns/1ps -generic_top BYTES=$bytes -generic_top TRANSACTIONS=$Transactions" |
            Set-Content -LiteralPath "$name.elab" -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f "$name.elab"
        if ($LASTEXITCODE -ne 0) { throw "Cache elaboration failed: $name" }
        $runSeeds = if ($bytes -eq 2048) { $Seeds } else { @($Seeds[0]) }
        foreach ($seed in $runSeeds) {
            $log = "${name}_seed$seed.log"
            "$name -runall -onerror quit -log $log -testplusarg SEED=$seed" | Set-Content -LiteralPath "$name.args" -Encoding ascii
            & (Join-Path $Vivado 'bin/xsim.bat') -f "$name.args"
            if ($LASTEXITCODE -ne 0) { throw "Cache simulation failed: $log" }
            $text = Get-Content -LiteralPath $log -Raw
            if ($text -notmatch 'CACHE_TEST_PASS' -or $text -match '(?im)^\s*(Fatal|Error):') { throw "Cache checks failed: $log" }
        }
    }
    Write-Host 'CACHE_UNIT_PASS'
} finally { Pop-Location }
