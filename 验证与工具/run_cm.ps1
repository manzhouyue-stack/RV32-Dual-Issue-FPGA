# CoreMark RTL run on actual B subsystem + vendor DRM models (XSim).
# -Cpu selects the CPU source folder; -Mode perf|val selects the RAM INIT set.
param(
 [ValidateSet('cpu_v04','cpu_v05','cpu_v06','cpu_v07')][string]$Cpu='cpu_v05',
 [ValidateSet('perf','val')][string]$Mode='perf',
 [string]$Tag='',
 [switch]$Stats,
 [switch]$Trace,
 [string]$VivadoRoot='C:/Xilinx/Vivado/2021.1',
 [string]$PangoRoot='C:/pango/PDS_2023.2-SP3-ads'
)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$soc=Join-Path $here 'soc'
$ipRoot=if($Mode -eq 'val'){Join-Path $here 'ip_val1'}else{Join-Path $soc 'ip'}
$name="${Cpu}_${Mode}"+$(if($Tag){"_$Tag"}else{''})
$out=Join-Path $here "runs/$name"
if(Test-Path $out){Remove-Item -Recurse -Force $out}
New-Item -ItemType Directory -Path $out | Out-Null
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot/lib/win64.o;$VivadoRoot/bin;$VivadoRoot/tps/mingw/6.2.0/win64.o/nt/bin;$env:PATH"
$vendor="$PangoRoot/arch/vendor/pango/verilog/simulation"
$cpuDir=Join-Path $here $Cpu
$cpuFiles=@("$cpuDir/rv32_pkg.sv")+@(Get-ChildItem $cpuDir -Filter *.sv | Where-Object Name -ne 'rv32_pkg.sv' | ForEach-Object FullName)
$socFiles=@('tcm_subsystem.sv','fifo16x8.v','uart_transport.v','cycle_counter64.v','mmio_regs.v','mem_io_subsystem.v') | ForEach-Object {"$soc/source/$_"}
$coreTop=if($Cpu -eq 'cpu_v04'){"$soc/source/soc_stage1_core.sv"}else{"$here/soc_v05/soc_stage1_core.sv"}
$ip=@()
foreach($b in 'itcm','dtcm'){$ip+=@("$ipRoot/soc_${b}_ram/soc_${b}_ram.v","$ipRoot/soc_${b}_ram/rtl/ipm2l_dpram_v1_10_soc_${b}_ram.v")}
$prims=@('GTP_GRS','GTP_DRM36K_E1') | ForEach-Object {"$vendor/$_.v"}
$def=if($Mode -eq 'val'){'AC_VALIDATION'}else{'AC_PERFORMANCE'}
Push-Location $out
try{
 $opts=@('-sv','-d',$def,'-d','RV32_SIM_CHECKS','-i',"$ipRoot/soc_itcm_ram/rtl",'-i',"$ipRoot/soc_dtcm_ram/rtl")
 if($Stats -or $Trace){$opts+=@('-d','CPU_STATS')}
 if($Trace){$opts+=@('-d','CPU_TRACE')}
 & "$VivadoRoot/bin/xvlog.bat" @($opts+$prims+$ip+$cpuFiles+$socFiles+@($coreTop,"$here/tb_ac_coremark.sv")) *> xvlog.console.log
 if($LASTEXITCODE){Get-Content xvlog.console.log -Tail 30;throw 'xvlog failed'}
 & "$VivadoRoot/bin/xelab.bat" tb_ac_coremark -s sim -timescale 1ns/1ps *> xelab.console.log
 if($LASTEXITCODE){Get-Content xelab.console.log -Tail 30;throw 'xelab failed'}
 $t0=Get-Date
 & "$VivadoRoot/bin/xsim.bat" sim -R -log xsim.log *> xsim.console.log
 $wall=((Get-Date)-$t0).TotalSeconds
 $log=Get-Content xsim.log -Raw
 $ticks=[regex]::Matches($log,'Total ticks\s+:\s+(\d+)') | ForEach-Object {[int64]$_.Groups[1].Value}
 $pass=$log -match 'PASS AC_COREMARK'
 $status=if($pass){'PASS'}else{'FAIL'}
 $tl=$ticks -join ','
 Write-Output "$status $name ticks=$tl wall=$([int]$wall)s"
 Select-String -Path xsim.log -Pattern 'CPU_STATS' | ForEach-Object Line
 if(-not $pass){Get-Content xsim.log -Tail 15}
}finally{Pop-Location}
