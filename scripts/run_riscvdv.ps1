param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python',
    [int]$Seed = 1,
    [int]$MaxDelay = 5
)
# Run riscv-dv programs (built by scripts/riscvdv_gen.sh) on the pipeline core in
# XSim with the default 64 KiB pipe_tb, then check every RTL trace against the
# independent Python model with the existing scripts/check_pipeline_trace.py.
# Spike was already checked against the same model by riscvdv_prepare.py, so a
# program that passes both means the RTL and Spike retire the same instructions.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dv = Join-Path $root "build/riscv-dv/$Tag"
$out = Join-Path $dv 'xsim'
$manifest = Get-Content -LiteralPath (Join-Path $dv 'manifest.json') -Raw | ConvertFrom-Json
$ready = @($manifest | Where-Object { $_.status -eq 'READY' })
New-Item -ItemType Directory -Force $out | Out-Null
function Invoke-Xilinx([string]$Tool, [string[]]$ToolArgs) {
    & (Join-Path $Vivado "bin/$Tool.bat") @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed: $LASTEXITCODE" }
}
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv', 'rtl/core/alu.sv',
        'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv', 'rtl/core/muldiv_unit.sv',
        'rtl/core/csr_file.sv', 'rtl/core/core_pipeline.sv', 'tb/core/pipe_tb.sv') | ForEach-Object { Join-Path $root $_ }
    Invoke-Xilinx 'xvlog' (@('--sv') + $sources)
    Invoke-Xilinx 'xelab' @('pipe_tb', '-s', 'pipe_tb', '--timescale', '1ns/1ps', '--debug', 'typical')
    foreach ($entry in $ready) {
        $name = "$($entry.program)_s${Seed}_d${MaxDelay}"
        $image = (Join-Path $dv "images/$($entry.program).hex").Replace('\', '/')
        $trace = (Join-Path $out "$name.csv").Replace('\', '/')
        @('pipe_tb', '-runall', '-onerror quit', "-log $name.log",
            "-testplusarg IMAGE=$image", "-testplusarg TRACE=$trace", "-testplusarg SEED=$Seed",
            "-testplusarg MAX_DELAY=$MaxDelay") | Set-Content -LiteralPath "$name.args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$name.args" | Out-Null
        Write-Host "SIMULATED: $name"
    }
} finally { Pop-Location }
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/riscvdv_check.py "build/riscv-dv/$Tag" --seed $Seed --max-delay $MaxDelay
if ($LASTEXITCODE -ne 0) { throw 'riscvdv_check.py reported failures' }
