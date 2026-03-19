#Requires -PSEdition Core

# .SYNOPSIS
# deploy_prefs.ps1
#
# Deployment for Andrew's personal preferences (prefs repo).
# Can be run standalone (cafe/VM) or called by deploy_de.ps1.
param ([switch] $Force, [string[]] $Suppress = @(), [string[]] $Enable = @(), [hashtable] $Config = @{})
$ErrorActionPreference = "Stop"

Import-Module "$home\prat\lib\TextFileEditor\TextFileEditor.psd1"
Import-Module "$home\prat\lib\Installers\Installers.psd1"

$it = $null

try {
    $it = Start-Installation "prefs" -InstallationDatabaseLocation "$home\prat\auto\instDb" -Force:$Force

    $libInst = "$home\prefs\lib\inst"
    & $libInst\packages_prefs.ps1              $it $Suppress  # install packages first; agentConfig etc. depend on claude being present
    & $libInst\powerToys_prefs.ps1             $it
    & $libInst\agentConfig_prefs.ps1           $it $Suppress $Enable $Config
    & $libInst\schTasks_prefs.ps1              $it $Suppress
    & $libInst\keyboard_prefs.ps1     $it
    & $libInst\mouse_prefs.ps1        $it
    & $libInst\updatePsHelp_prefs.ps1 $it
    & $libInst\vscode_prefs.ps1          $it $Suppress
    & $libInst\procmonSettings_prefs.ps1 $it
    & $libInst\gitconfig_prefs.ps1             $it $Config
    & $libInst\googleChrome_prefs.ps1          $it $Suppress
    & $libInst\autoHotKey_prefs.ps1 $it $Suppress  # must precede windowsCustomizations (taskpane icons step references AHK)
    & $libInst\windowsCustomizations_prefs.ps1 $it

} catch {
    if ($null -ne $it) { $it.ReportErrorContext($error[0]) }
    throw
} finally {
    if ($null -ne $it) { $it.StopInstallation() }
}
