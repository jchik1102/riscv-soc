param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [int[]]$Seeds = @(1, 2, 3),
    [int]$Transactions = 6000,
    [switch]$SkipCompile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/xsim_sdram'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    if (!$SkipCompile) {
        $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/memory/sdram_ctrl.sv', 'rtl/memory/sdram_tester.sv',
            'tb/unit/sdram_model.sv', 'tb/unit/sdram_tb.sv', 'tb/unit/sdram_tester_tb.sv') | ForEach-Object { Join-Path $root $_ }
        & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources
        if ($LASTEXITCODE -ne 0) { throw 'SDRAM compilation failed' }
    }
    $configs = @(@{name = 'sdram_50'; clk = 20000})
    $configs += @{name = 'sdram_100'; clk = 10000}
    foreach ($config in $configs) {
        "sdram_tb -s $($config.name) --timescale 1ns/1ps -generic_top CLK_PS=$($config.clk) -generic_top TRANSACTIONS=$Transactions" |
            Set-Content -LiteralPath "$($config.name).elab" -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f "$($config.name).elab"
        if ($LASTEXITCODE -ne 0) { throw "SDRAM elaboration failed: $($config.name)" }
        $runSeeds = if ($config.clk -eq 20000) { $Seeds } else { @($Seeds[0]) }
        foreach ($seed in $runSeeds) {
            $log = "$($config.name)_seed$seed.log"
            "$($config.name) -runall -onerror quit -log $log -testplusarg SEED=$seed" | Set-Content -LiteralPath "$($config.name).args" -Encoding ascii
            & (Join-Path $Vivado 'bin/xsim.bat') -f "$($config.name).args"
            if ($LASTEXITCODE -ne 0) { throw "SDRAM simulation failed: $log" }
            $text = Get-Content -LiteralPath $log -Raw
            if ($text -notmatch 'SDRAM_TEST_PASS' -or $text -match '(?im)^\s*(Fatal|Error):') { throw "SDRAM checks failed: $log" }
        }
    }
    & (Join-Path $Vivado 'bin/xelab.bat') sdram_tester_tb -s sdram_tester --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'SDRAM tester elaboration failed' }
    & (Join-Path $Vivado 'bin/xsim.bat') sdram_tester -runall -onerror quit -log sdram_tester.log
    if ($LASTEXITCODE -ne 0) { throw 'SDRAM tester simulation failed' }
    $text = Get-Content -LiteralPath sdram_tester.log -Raw
    if ($text -notmatch 'SDRAM_TESTER_TEST_PASS' -or $text -match '(?im)^\s*(Fatal|Error):') { throw 'SDRAM tester checks failed' }
    Write-Host 'SDRAM_UNIT_PASS'
} finally { Pop-Location }
