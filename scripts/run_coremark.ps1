param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    # bpred: the core as built; nobpred: +define+NO_BPRED, the pre-prediction front end.
    [ValidateSet('bpred', 'nobpred')][string]$Variant = 'bpred',
    # coremark: build/coremark/coremark.hex (scripts/coremark_build.sh);
    # fir: the S3 FIR benchmark, build/programs/asm_fir.hex (scripts/programs.py).
    [ValidateSet('coremark', 'fir')][string]$Program = 'coremark',
    [long]$MaxCycles = 200000000
)
# Run a benchmark on the pipeline core in tb/core/coremark_tb.sv and check its
# result. Prints COREMARK_RUN_PASS or throws.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root "build/coremark/xsim_${Program}_$Variant"
New-Item -ItemType Directory -Force $out | Out-Null
function Invoke-Xilinx([string]$Tool, [string[]]$ToolArgs) {
    & (Join-Path $Vivado "bin/$Tool.bat") @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed: $LASTEXITCODE" }
}
$relative = if ($Program -eq 'fir') { 'build/programs/asm_fir.hex' } else { 'build/coremark/coremark.hex' }
$image = (Join-Path $root $relative).Replace('\', '/')
if (!(Test-Path -LiteralPath $image)) { throw "Missing $image; run scripts/coremark_build.sh or scripts/programs.py" }
Push-Location $out
try {
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/core/core_pkg.sv', 'rtl/core/decoder.sv',
        'rtl/core/alu.sv', 'rtl/core/load_store.sv', 'rtl/core/regfile.sv', 'rtl/core/mul_iter.sv', 'rtl/core/div_iter.sv',
        'rtl/core/muldiv_unit.sv', 'rtl/core/csr_file.sv', 'rtl/core/core_pipeline.sv', 'tb/core/coremark_tb.sv') |
        ForEach-Object { Join-Path $root $_ }
    $defines = if ($Variant -eq 'nobpred') { @('-d', 'NO_BPRED') } else { @() }
    Invoke-Xilinx 'xvlog' (@('--sv') + $defines + $sources)
    Invoke-Xilinx 'xelab' @('coremark_tb', '-s', 'coremark_tb', '--timescale', '1ns/1ps')
    @('coremark_tb', '-runall', '-onerror quit', "-log coremark.log",
        "-testplusarg IMAGE=$image", "-testplusarg MAX_CYCLES=$MaxCycles") |
        Set-Content -LiteralPath 'coremark.args' -Encoding ascii
    Invoke-Xilinx 'xsim' @('-f', 'coremark.args')
    $log = Get-Content -LiteralPath 'coremark.log' -Raw
    if ($log -notmatch 'COREMARK_TB_DONE' -or $log -match '(?im)^\s*(Fatal|Error):') { throw "Simulation failed ($Program, $Variant)" }
    if ($Program -eq 'fir') {
        # sw/fir.c sets status 1 only if its checksum matches the Python reference.
        if ($log -notmatch 'REPORT magic=4649523151313500 checksum=000000000fc6e755 status=1') { throw "FIR result wrong ($Variant)" }
    } else {
        # The 2K performance run's CRCs (CoreMark README) prove correct execution.
        # A short simulated run always breaks CoreMark's 10-second rule, which
        # core_main counts as an error; any other error fails the run.
        foreach ($crc in @('seedcrc\s*:\s*0xe9f5', 'crclist\s*:\s*0xe714', 'crcmatrix\s*:\s*0x1fd7', 'crcstate\s*:\s*0x8e3a')) {
            if ($log -notmatch $crc) { throw "CoreMark CRC check failed ($Variant): $crc" }
        }
        $errors = [regex]::Matches($log, '(?m)^.*ERROR!.*$') | ForEach-Object { $_.Value } | Where-Object { $_ -notmatch 'at least 10 secs' }
        if ($errors) { throw "CoreMark reported errors ($Variant): $($errors -join '; ')" }
    }
    Write-Host "COREMARK_RUN_PASS program=$Program variant=$Variant log=$out/coremark.log"
} finally { Pop-Location }
