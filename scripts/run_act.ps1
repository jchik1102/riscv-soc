param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [int]$Seed = 1,
    [int]$MaxDelay = 5,
    [string[]]$Tests = @(),
    # Directory of mutated RTL files (from scripts/pipeline_mutants.py) that replace
    # same-named files in rtl/core, to show the ACT runs detect real defects.
    [string]$RtlOverride = '',
    [string]$Label = ''
)
# Run the riscv-arch-test (ACT4) images on the pipeline core in XSim, then let
# scripts/act_check.py read each test's tohost result from the final memory
# dump. Build the images first with scripts/act_build.sh (WSL).
# pipe_tb is compiled with a 256 KiB memory (TB_MEM_BYTES); the RTL is unchanged.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root $(if ($Label) { "build/xsim_act_$Label" } else { 'build/xsim_act' })
$manifest = Join-Path $root 'build/act4/images/manifest.json'
if (!(Test-Path -LiteralPath $manifest)) { throw 'Missing build/act4/images/manifest.json; run scripts/act_build.sh' }
$entries = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
if ($Tests.Count -gt 0) { $entries = @($entries | Where-Object { $Tests -contains $_.test }) }
New-Item -ItemType Directory -Force $out | Out-Null
function Invoke-Xilinx([string]$Tool, [string[]]$ToolArgs) {
    & (Join-Path $Vivado "bin/$Tool.bat") @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed: $LASTEXITCODE" }
}
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv',
        'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv',
        'rtl/core/csr_file.sv', 'rtl/core/core_pipeline.sv', 'tb/core/pipe_tb.sv') | ForEach-Object {
        $override = if ($RtlOverride) { Join-Path $RtlOverride (Split-Path $_ -Leaf) } else { '' }
        if ($override -and (Test-Path -LiteralPath $override)) { $override } else { Join-Path $root $_ }
    }
    # The .bat loader splits arguments at '=', so the define goes through an options file.
    (@('--sv', '--define TB_MEM_BYTES=262144') + ($sources | ForEach-Object { '"' + $_.Replace('\', '/') + '"' })) |
        Set-Content -LiteralPath 'xvlog.args' -Encoding ascii
    Invoke-Xilinx 'xvlog' @('-f', 'xvlog.args')
    Invoke-Xilinx 'xelab' @('pipe_tb', '-s', 'pipe_tb', '--timescale', '1ns/1ps', '--debug', 'typical')
    foreach ($entry in $entries) {
        $name = "$($entry.test)_s${Seed}_d${MaxDelay}"
        $image = (Join-Path $root "build/act4/images/$($entry.test).hex").Replace('\', '/')
        $trace = (Join-Path $out "$name.csv").Replace('\', '/')
        @('pipe_tb', '-runall', '-onerror quit', "-log $name.log",
            "-testplusarg IMAGE=$image", "-testplusarg TRACE=$trace", "-testplusarg SEED=$Seed",
            "-testplusarg MAX_DELAY=$MaxDelay") | Set-Content -LiteralPath "$name.args" -Encoding ascii
        # A failing test is recorded by act_check.py, not treated as a script error.
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$name.args" | Out-Null
        Write-Host "SIMULATED: $name"
    }
} finally { Pop-Location }
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/act_check.py --seed $Seed --max-delay $MaxDelay --label $Label
if ($LASTEXITCODE -ne 0 -and !$RtlOverride) { throw 'act_check.py reported failures' }
