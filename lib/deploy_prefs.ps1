#Requires -PSEdition Core

# .SYNOPSIS
# deploy_prefs.ps1
#
# Deployment for Andrew's personal preferences (prefs repo).
# Can be run standalone (cafe/VM) or called by deploy_de.ps1.
using module ..\..\prat\lib\TextFileEditor\TextFileEditor.psd1
using module ..\..\prat\lib\Installers\Installers.psd1

param ([switch] $Force)
$ErrorActionPreference = "Stop"

$it = $null

try {
    $it = Start-Installation "prefs" -InstallationDatabaseLocation "$home\prat\auto\instDb" -Force:$Force

    $libInst = "$home\prefs\lib\inst"
    & $libInst\keyboard_prefs.ps1     $it
    & $libInst\mouse_prefs.ps1        $it
    & $libInst\updatePsHelp_prefs.ps1 $it
    & $libInst\vscode_prefs.ps1          $it
    & $libInst\procmonSettings_prefs.ps1 $it

} catch {
    if ($null -ne $it) { $it.ReportErrorContext($error[0]) }
    throw
} finally {
    if ($null -ne $it) { $it.StopInstallation() }
}
