#Requires -PSEdition Core, Desktop

# Bootstrap script for the prefs repo.
# Installs prat, then runs Install-PrefsPhase2 to install packages.
param ([switch] $Force, [switch] $InteractiveUser = $true)
$ErrorActionPreference = "Stop"
$it = $null

function STEP($msg) { Write-Host -ForegroundColor Green "Install-Prefs.ps1: $msg" }

if (!(Test-Path "$home/prat")) {
    STEP "Install Prat"
    curl.exe -L -o $env:temp\Install-Prat.ps1 https://github.com/AndrewGodfrey/prat/raw/main/lib/Install-Prat.ps1
    if ($lastExitCode -ne 0) { throw "curl.exe failed: $lastExitCode" }

    . $env:temp\Install-Prat.ps1 -Force:$Force -InteractiveUser:$InteractiveUser
}

# Hmm. pwd seems to affect "using module ../../foo.psd1". Hack for now:
pushd $PSScriptRoot
try {
    STEP "Install-PrefsPhase2"
    # Now we can pass control to a "phase 2" script that uses Prat modules and PowerShell Core.
    pwsh $PSScriptRoot\Install-PrefsPhase2.ps1 -Force:$Force
} finally { popd }
