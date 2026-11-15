# Builds the board image of every demo stage (S3 to S8) and records each one's
# worst setup and hold slack in results/board/build_timing.txt. A stage whose
# image does not meet timing at the default fitter seed is retried with the
# other seeds listed; the seed used is recorded. Run before `make board-log`.
param([string[]]$Stages = @('s3', 's4', 's5', 's6', 's7', 's8'), [int[]]$Seeds = @(4, 2, 3, 1))
$ErrorActionPreference = 'Stop'
# pwsh -File passes a comma list as one token, so split it here.
$Stages = $Stages | ForEach-Object { $_ -split ',' }
$Seeds = $Seeds | ForEach-Object { "$_" -split ',' } | ForEach-Object { [int]$_ }
$root = Split-Path $PSScriptRoot -Parent
$demoOf = @{s3 = 'fir'; s4 = 's4'; s5 = 's5'; s6 = 's6'; s7 = 's7'; s8 = 's8'}
$outDir = Join-Path $root 'results/board'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$report = Join-Path $outDir 'build_timing.txt'
if (!(Test-Path $report)) {
    'Board images with the JTAG readout: Quartus Prime Lite 24.1std, 10M50DAF484C7G. Worst slack (ns) over all corners and clocks.' |
        Set-Content -LiteralPath $report -Encoding utf8
}
$failed = @()
foreach ($stage in $Stages) {
    $met = $false
    foreach ($seed in $Seeds) {
        & (Join-Path $PSScriptRoot 'build_board.ps1') -Stage $stage -Demo $demoOf[$stage] -Seed $seed | Out-Null
        $files = Join-Path $root "build/quartus_board_${stage}_p1/output_files/de10_lite_${stage}_p1"
        $lines = Get-Content "$files.sta.summary"
        $worst = @{Setup = [double]::MaxValue; Hold = [double]::MaxValue}
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^Type\s+:\s+.* (Setup|Hold) '") {
                $slack = [double](($lines[$i + 1] -split ':')[1])
                if ($slack -lt $worst[$Matches[1]]) { $worst[$Matches[1]] = $slack }
            }
        }
        $elements = ((Get-Content "$files.fit.summary") -match 'Total logic elements')[0] -replace '.*:\s*', ''
        $met = $worst.Setup -ge 0 -and $worst.Hold -ge 0
        $hash = (Get-FileHash -LiteralPath "$files.sof" -Algorithm SHA256).Hash.ToLower()
        $line = "stage=$stage seed=$seed worst_setup=$($worst.Setup) worst_hold=$($worst.Hold) timing=$(if ($met) { 'met' } else { 'NOT MET' }) logic_elements=`"$elements`" sof_sha256=$hash"
        $line | Tee-Object -FilePath $report -Append | Write-Host
        if ($met) {
            Copy-Item "$files.sta.summary", "$files.fit.summary" $outDir -Force
            break
        }
    }
    if (!$met) { $failed += $stage }
}
if ($failed) { throw "No seed met timing for: $($failed -join ', ')" }
Write-Host "BOARD_IMAGES_PASS: $($Stages -join ' ') built and timing met"
