param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Distro = 'Ubuntu',
    [string]$LinuxPython = '/home/jonat/.venvs/riscv-soc/bin/python'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$env:XILINX_VIVADO = $Vivado
foreach ($dir in 'build/uvm_pipeline', 'build/uvm_multicycle') {
    if (Test-Path -LiteralPath (Join-Path $root $dir)) { Remove-Item -Recurse -Force (Join-Path $root $dir) }
}
$programs = Get-Content -LiteralPath (Join-Path $root 'build/programs/manifest.json') -Raw | ConvertFrom-Json
$uvm = Join-Path $PSScriptRoot 'run_uvm.ps1'
& $uvm -Core pipeline -Test cpu_random_test -Seed 1 -MaxDelay 5 -Programs 12
foreach ($seed in 2, 3, 4) { & $uvm -Core pipeline -Test cpu_random_test -Seed $seed -MaxDelay 5 -Programs 12 -SkipCompile }
& $uvm -Core pipeline -Test cpu_random_test -Seed 5 -MaxDelay 0 -Programs 12 -AlwaysReady -SkipCompile
& $uvm -Core pipeline -Test cpu_random_test -Seed 6 -MaxDelay 9 -Programs 12 -SkipCompile
& $uvm -Core pipeline -Test cpu_image_test -Seed 1 -MaxDelay 5 -Cases $programs -SkipCompile
& $uvm -Core pipeline -Test cpu_image_test -Seed 7 -MaxDelay 3 -Cases @('pipe_random_3', 'm_mixed', 'memory_sizes') -ResetAfter 300 -SkipCompile
& $uvm -Core pipeline -Test cpu_image_test -Seed 8 -MaxDelay 2 -Cases @('reset_store', 'pipe_forward') -ResetAfter 25 -SkipCompile
& $uvm -Core multicycle -Test cpu_random_test -Seed 1 -MaxDelay 5 -Programs 6
& $uvm -Core multicycle -Test cpu_image_test -Seed 1 -MaxDelay 5 -SkipCompile `
    -Cases @('first', 'control', 'memory_sizes', 'm_mixed', 'asm_muldiv', 'fault_load_bounds', 'fault_fetch_high', 'pipe_forward')
foreach ($core in 'pipeline', 'multicycle') {
    Push-Location (Join-Path $root "build/uvm_$core")
    try {
        $dbArgs = @()
        foreach ($db in Get-ChildItem -Directory 'xsim.covdb' | Where-Object Name -ne 'merged') { $dbArgs += @('-cov_db_name', $db.Name) }
        & (Join-Path $Vivado 'bin/xcrg.bat') -cov_db_dir . @dbArgs -merge_dir . -merge_db_name merged -report_dir coverage_report -report_format text
        if ($LASTEXITCODE -ne 0) { throw "xcrg failed for $core" }
        if (!(Test-Path -LiteralPath 'coverage_report/functionalCoverageReport/xcrg_func_cov_report.txt')) { throw "No merged coverage report for $core" }
    } finally { Pop-Location }
}
$linuxRoot = ((& wsl -d $Distro --exec wslpath -a $root) | Out-String).Trim()
& wsl -d $Distro --cd $linuxRoot --exec $LinuxPython scripts/check_uvm_runs.py --spike
if ($LASTEXITCODE -ne 0) { throw 'Python/Spike re-check of UVM transcripts failed' }
Write-Host 'UVM_REGRESSION_PASS: random and directed UVM runs, merged coverage, Python and Spike re-checks'
