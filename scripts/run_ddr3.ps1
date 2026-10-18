param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [int]$Ops = 3000,
    [string]$Mem = '1,0',    # back ends to run; a comma list (pwsh -File passes it as one token)
    [string]$Out = ''
)
# tb/ddr3/ddr3_bridge_tb.sv in XSim: MEM=1 is the DDR3 path (ddr3_bridge, the
# MIG's simulation build, Micron's DDR3 model), MEM=0 the SDR SDRAM path
# (sdram_ctrl, sdram_model) under the same traffic and measurements. The MIG
# and the Micron model come from the generated IP in build/mig/
# (fpga/arty_a7/gen_mig.tcl, run here if it is missing); they are not in the
# repository. Logs in build/xsim_ddr3/; prints DDR3_SIM_PASS.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = if ($Out) { $Out } else { Join-Path $root 'build/xsim_ddr3' }
New-Item -ItemType Directory -Force $out | Out-Null
$mig = Join-Path $root 'build/mig'
$rtl = Join-Path $mig 'ip/mig_ddr3/mig_ddr3/user_design/rtl'
$model = Join-Path $mig 'example/mig_ddr3_ex/imports'
if (!(Test-Path (Join-Path $rtl 'mig_ddr3.v'))) {
    New-Item -ItemType Directory -Force (Join-Path $root 'build/mig_gen') | Out-Null
    Push-Location (Join-Path $root 'build/mig_gen')
    try {
        & (Join-Path $Vivado 'bin/vivado.bat') -mode batch -nojournal -log gen_mig.log -source ((Join-Path $root 'fpga/arty_a7/gen_mig.tcl').Replace('\', '/'))
        if ($LASTEXITCODE -ne 0) { throw 'MIG generation failed' }
    } finally { Pop-Location }
}
Push-Location $out
try {
    # MIG user design for simulation: every file except the synthesis top-level wrapper.
    $migFiles = Get-ChildItem -Path $rtl -Recurse -Filter '*.v' | Where-Object { $_.Name -ne 'mig_ddr3_mig.v' } |
        ForEach-Object { $_.FullName }
    & (Join-Path $Vivado 'bin/xvlog.bat') @migFiles (Join-Path $Vivado 'data/verilog/src/glbl.v') | Out-File -Encoding ascii compile_mig.log
    if ($LASTEXITCODE -ne 0) { throw 'MIG compilation failed (build/xsim_ddr3/compile_mig.log)' }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv -i $model -d x2Gb -d sg15E -d x16 (Join-Path $model 'ddr3_model.sv') |
        Out-File -Encoding ascii compile_model.log
    if ($LASTEXITCODE -ne 0) { throw 'DDR3 model compilation failed' }
    $sources = @('rtl/soc/platform_pkg.sv', 'rtl/soc/soc_pkg.sv', 'rtl/memory/async_fifo.sv', 'rtl/memory/ddr3_bridge.sv',
        'rtl/memory/sdram_ctrl.sv', 'tb/unit/sdram_model.sv', 'tb/ddr3/ddr3_bridge_tb.sv') | ForEach-Object { Join-Path $root $_ }
    & (Join-Path $Vivado 'bin/xvlog.bat') --sv @sources | Out-File -Encoding ascii compile_tb.log
    if ($LASTEXITCODE -ne 0) { throw 'Bridge bench compilation failed (build/xsim_ddr3/compile_tb.log)' }
    foreach ($m in ($Mem -split ',' | ForEach-Object { [int]$_.Trim() })) {
        $name = "bridge_mem$m"
        "ddr3_bridge_tb glbl -s $name --timescale 1ns/1ps -L unisims_ver -L secureip -generic_top MEM=$m -generic_top OPS=$Ops" |
            Set-Content -LiteralPath "$name.elab" -Encoding ascii
        & (Join-Path $Vivado 'bin/xelab.bat') -f "$name.elab" | Out-File -Encoding ascii "elab_$name.log"
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed: $name (build/xsim_ddr3/elab_$name.log)" }
        "$name -runall -onerror quit -log $name.log" | Set-Content -LiteralPath "$name.args" -Encoding ascii
        & (Join-Path $Vivado 'bin/xsim.bat') -f "$name.args" | Out-Null
        $log = Get-Content -LiteralPath "$name.log" -Raw
        $pass = [regex]::Match($log, '(?m)^(DDR3|SDR)_BRIDGE_TB_PASS .*$').Value
        # The Micron model reports protocol and timing violations as "... ERROR: ...".
        if (!$pass -or $log -match '(?im)^\s*(Fatal|Error):' -or $log -cmatch 'ERROR') { throw "Bridge bench failed: build/xsim_ddr3/$name.log" }
        Write-Host $pass
    }
} finally { Pop-Location }
Write-Host 'DDR3_SIM_PASS'
