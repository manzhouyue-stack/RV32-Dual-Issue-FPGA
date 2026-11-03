$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pkg = Join-Path $repo 'rtl/rv32_pkg.sv'
$sources = @($pkg) + @((Get-ChildItem (Join-Path $repo 'rtl') -Filter '*.sv' |
    Where-Object Name -ne 'rv32_pkg.sv').FullName)

foreach ($top in @('tb_units', 'tb_core', 'tb_control', 'tb_illegal', 'tb_freeze_mmio', 'tb_trace')) {
    $exe = Join-Path $env:TEMP "$top.vvp"
    $compileLog = Join-Path $env:TEMP "$top.compile.log"
    & iverilog -g2012 -s $top -o $exe $sources (Join-Path $PSScriptRoot "$top.sv") 2> $compileLog
    if ($LASTEXITCODE -ne 0) {
        Get-Content $compileLog
        exit $LASTEXITCODE
    }
    & vvp $exe | Select-String 'PASS'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
& python (Join-Path $PSScriptRoot 'compare_trace.py')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& python (Join-Path $PSScriptRoot 'run_rv32ui.py') 2> (Join-Path $env:TEMP 'rv32ui.compile.log') | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& python (Join-Path $PSScriptRoot 'compare_rv32ui_spike.py') |
    Select-Object -Last 1
exit $LASTEXITCODE
