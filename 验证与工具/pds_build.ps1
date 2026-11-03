# Run the full PDS flow for a build directory and summarize timing/resources.
param([Parameter(Mandatory=$true)][string]$Dir,[string]$PdsRoot='C:/pango/PDS_2023.2-SP3-ads')
$env:PROCESSOR_ARCHITECTURE='AMD64'
$lic=[Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','Machine'); if($lic){$env:PANGO_LICENSE_FILE=$lic}
Push-Location $Dir
try{
 $t0=Get-Date
 & "$PdsRoot/bin/pds_shell.exe" -project soc_stage1.pds -run gen_bit_stream *> build-console.log
 $code=$LASTEXITCODE
 Write-Output "pds exit=$code wall=$([int]((Get-Date)-$t0).TotalSeconds)s"
 Select-String -Path build-console.log -Pattern '^\s*(E:|C:|ERROR)' | Select-Object -First 10 | ForEach-Object Line
}finally{Pop-Location}
