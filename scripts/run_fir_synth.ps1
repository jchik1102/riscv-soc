param(
    [string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus',
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Part = 'xc7a100tcsg324-1',
    [int[]]$Lanes = @(1, 4, 16)
)
# Resources and timing of rtl/peripherals/fir_filter.sv alone, at 50 MHz, for
# each LANES value: a Quartus fit on the MAX 10 (fpga/fir/fir_fit.tcl) and a
# Vivado out-of-context implementation on an Artix-7 (scripts/vivado-impl.tcl).
# Writes build/fir_synth/summary.txt and prints FIR_SYNTH_DONE.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build/fir_synth'
New-Item -ItemType Directory -Force $out | Out-Null
$lines = @()
foreach ($l in $Lanes) {
    & (Join-Path $Quartus 'bin64/quartus_sh.exe') -t (Join-Path $root 'fpga/fir/fir_fit.tcl') $l
    if ($LASTEXITCODE -ne 0) { throw "Quartus fit failed: lanes=$l" }
    $q = Join-Path $root "build/quartus_fir_l$l/output_files"
    $fit = Get-Content -LiteralPath (Join-Path $q "fir_l$l.fit.summary") -Raw
    $sta = Get-Content -LiteralPath (Join-Path $q "fir_l$l.sta.summary") -Raw
    $le = [regex]::Match($fit, 'Total logic elements : (\S+ / \S+ \([^)]*\))').Groups[1].Value
    $regs = [regex]::Match($fit, 'Total registers : ([\d,]+)').Groups[1].Value
    $mult = [regex]::Match($fit, 'Embedded Multiplier 9-bit elements : ([\d,]+ / [\d,]+)').Groups[1].Value
    $setup = [regex]::Match($sta, "Type\s*: Slow 1200mV 85C Model Setup 'clk'\s*Slack\s*: (-?[\d.]+)").Groups[1].Value
    $hold = [regex]::Match($sta, "Type\s*: Slow 1200mV 85C Model Hold 'clk'\s*Slack\s*: (-?[\d.]+)").Groups[1].Value
    $lines += "QUARTUS lanes=$l logic_elements=$le registers=$regs mult9=$mult setup_slack_slow85c=$setup hold_slack_slow85c=$hold"
    Copy-Item -LiteralPath (Join-Path $q "fir_l$l.fit.summary"), (Join-Path $q "fir_l$l.sta.summary") -Destination $out -Force

    $v = (Join-Path $root "build/vivado/fir_l$l").Replace('\', '/')
    New-Item -ItemType Directory -Force $v | Out-Null
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/peripherals/fir_filter.sv') |
        ForEach-Object { (Join-Path $root $_).Replace('\', '/') }
    Push-Location $v
    try {
        & (Join-Path $Vivado 'bin/vivado.bat') -mode batch -nojournal -log vivado.log -source ((Join-Path $root 'scripts/vivado-impl.tcl').Replace('\', '/')) `
            -tclargs fir_filter $Part 20.0 $v "LANES:$l" none @sources
        if ($LASTEXITCODE -ne 0) { throw "Vivado failed: lanes=$l" }
    } finally { Pop-Location }
    $lines += (Get-Content -LiteralPath (Join-Path $v 'result.txt') -Raw).Trim() -replace '^VIVADO_', "VIVADO lanes=$l "
    foreach ($f in @('result.txt', 'utilization.txt', 'timing_summary.txt')) {
        Copy-Item -LiteralPath (Join-Path $v $f) -Destination (Join-Path $out "vivado_l${l}_$f") -Force
    }
}
$lines | Set-Content -LiteralPath (Join-Path $out 'summary.txt') -Encoding ascii
$lines | ForEach-Object { Write-Host $_ }
Write-Host 'FIR_SYNTH_DONE'
