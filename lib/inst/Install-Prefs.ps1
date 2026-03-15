#Requires -PSEdition Core, Desktop

# Bootstrap script for the prefs repo.
# Installs prat (from GitHub) if not already present.
param ([switch] $Force, [switch] $InteractiveUser = $true)
$ErrorActionPreference = "Stop"

if (!(Test-Path "$home/prat")) {
    Write-Host -ForegroundColor Green "Install-Prefs.ps1: Install Prat"
    curl.exe -L -o $env:temp\Install-Prat.ps1 https://github.com/AndrewGodfrey/prat/raw/main/lib/Install-Prat.ps1
    if ($lastExitCode -ne 0) { throw "curl.exe failed: $lastExitCode" }

    . $env:temp\Install-Prat.ps1 -Force:$Force -InteractiveUser:$InteractiveUser
}
