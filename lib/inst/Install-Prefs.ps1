#Requires -PSEdition Core, Desktop

# Bootstrap script for the prefs repo (cafe/VM standalone use).
# Installs prat (from GitHub) if not already present.
param ([switch] $Force, [switch] $InteractiveUser = $true)
$ErrorActionPreference = "Stop"

&$PSScriptRoot\Install-Prat.ps1 -Force:$Force -InteractiveUser:$InteractiveUser
