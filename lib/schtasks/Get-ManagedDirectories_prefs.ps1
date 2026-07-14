# See daily_cleanManagedDirectories.ps1
param([switch] $AddRecommendedDirectories = $false, [string] $UserName = $env:USERNAME)

. $home\prat\lib\schtasks\Get-ManagedDirectories_prat.ps1 -AddRecommendedDirectories

$agentTemp = "C:\Users\${UserName}_agent\AppData\Local\Temp"
if (Test-Path $agentTemp) {
    @{ path = $agentTemp; days = 14 }
}
