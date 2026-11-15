# Programs a stage's image on a connected DE10-Lite, waits for the demo to finish,
# and reads its results over JTAG (scripts/board_log.tcl) into results/board/<stage>.log.
# Build the image first with scripts/build_board.ps1. All switches down.
param([string]$Quartus = 'C:\intelFPGA_lite\24.1std\quartus',
      [ValidateSet('s3', 's4', 's5', 's6', 's7', 's8')][string]$Stage = 's8', [int]$Pipeline = 1,
      [string]$Cable = 'USB-Blaster [USB-0]', [int]$Timeout = 180)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$demo = @{s3 = 0; s4 = 1; s5 = 2; s6 = 3; s7 = 4; s8 = 5}[$Stage]
$sof = Join-Path $root "build/quartus_board_${Stage}_p$Pipeline/output_files/de10_lite_${Stage}_p$Pipeline.sof"
if (!(Test-Path -LiteralPath $sof)) { throw "Missing $sof; run scripts/build_board.ps1 -Stage $Stage" }
$outDir = Join-Path $root 'results/board'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$log = Join-Path $outDir "$Stage.log"

$lines = @(
    "board_log: stage $Stage, pipeline $Pipeline, DE10-Lite (10M50DAF484C7G), read over JTAG",
    "date: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))",
    "commit: $(git -C $root rev-parse HEAD)$(if (git -C $root status --porcelain -- rtl fpga sw scripts) { ' (+ uncommitted changes)' })",
    "image: build/quartus_board_${Stage}_p$Pipeline/output_files/de10_lite_${Stage}_p$Pipeline.sof",
    "image_sha256: $((Get-FileHash -LiteralPath $sof -Algorithm SHA256).Hash.ToLower())"
)
$lines | Set-Content -LiteralPath $log -Encoding utf8
$lines | Write-Host

& (Join-Path $Quartus 'bin64/quartus_pgm.exe') -c $Cable -m JTAG -o "p;$sof" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Programming failed ($LASTEXITCODE); is the DE10-Lite connected and powered?" }
'programmed: yes' | Tee-Object -FilePath $log -Append | Write-Host

& (Join-Path $Quartus 'bin64/quartus_stp.exe') -t (Join-Path $PSScriptRoot 'board_log.tcl') $demo $Timeout 2>&1 |
    ForEach-Object { "$_" } |
    Where-Object { $_ -notmatch '^(Info|\s+Info)\b' } |
    Tee-Object -FilePath $log -Append | Write-Host
if (!(Select-String -LiteralPath $log -Pattern '^BOARD_LOG_PASS' -Quiet)) { throw "Board log for $Stage did not pass; see $log" }
Write-Host "BOARD_LOG_SAVED: results/board/$Stage.log"
