# See daily_cleanManagedDirectories.ps1
param([switch] $AddRecommendedDirectories = $false, [string] $UserName = $env:USERNAME)

. $home\prat\lib\schtasks\Get-ManagedDirectories_prat.ps1 -AddRecommendedDirectories
# OmitFromCoverageReport: a unit test would just restate it - trivial passthrough
