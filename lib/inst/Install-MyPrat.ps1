#Requires -PSEdition Core, Desktop

# Installs Prat (customized for me).
# Ideally, this includes all settings I want in all dev environments.
#   (But, it can't install things that depend on the dev environment e.g. overridden files found via Resolve-PratLibFile.ps1)
# It should exclude things that are specific to one of my dev environments (that is: test machine; personal; work/whatever)
#
param ([switch] $Force, [switch] $InteractiveUser = $true)
$ErrorActionPreference = "Stop"

function STEP($msg) { Write-Host -ForegroundColor Green "Install-MyPrat.ps1: $msg" }

if (!(Test-Path "$home/prat")) {
    STEP "Install Prat"
    curl.exe -L -o $env:temp\Install-Prat.ps1 https://github.com/AndrewGodfrey/prat/raw/main/lib/Install-Prat.ps1
    if ($lastExitCode -ne 0) { throw "curl.exe failed: $lastExitCode" }

    . $env:temp\Install-Prat.ps1 -Force:$Force -InteractiveUser:$InteractiveUser
}
