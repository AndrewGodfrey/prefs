param([switch]$Force)
& "$home/prat/lib/deployLayer_prat.ps1" -Force:$Force
& "$PSScriptRoot/deployLayer_prefs.ps1" -Force:$Force
