#Requires -PSEdition Core, Desktop

# Installs Prat from GitHub, if not already present.
param ([switch] $Force, [switch] $InteractiveUser = $true)
$ErrorActionPreference = "Stop"

if (!(Test-Path "$home/prat")) {
    Write-Host -ForegroundColor Green "'prefs' repo Install-Prat.ps1: Launching 'prat' repo Install-Prat.ps1"
    curl.exe -L -o $env:temp\Install-Prat.ps1 https://github.com/AndrewGodfrey/prat/raw/main/lib/Install-Prat.ps1
    if ($lastExitCode -ne 0) { throw "curl.exe failed: $lastExitCode" }

    . $env:temp\Install-Prat.ps1 -Force:$Force -InteractiveUser:$InteractiveUser
}
