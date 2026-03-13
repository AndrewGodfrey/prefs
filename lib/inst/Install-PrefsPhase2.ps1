#Requires -PSEdition Core

using module ../../prat/lib/TextFileEditor/TextFileEditor.psd1
using module ../../prat/lib/Installers/Installers.psd1

param ([switch] $Force, [switch] $InteractiveUser = $true)
$it = $null

try {
    $it = Start-Installation "prat bootstrap" -InstallationDatabaseLocation "$home\prat\auto\instDb" -Force:$Force

    $packages = @("wget", "df")
    if ($InteractiveUser) { $packages += @("ditto", "sysinternals") }

    foreach ($packageId in $packages) { Install-PratPackage $it $packageId }

    if ($InteractiveUser) {
        Install-PratPackage $it "winmerge"

        # Install-PratPackage $it "windbg"

        # Install-PratPackage $it "dnspy"
    }
} catch {
    if ($null -ne $it) { $it.ReportErrorContext($error[0]) }
    throw
} finally {
    if ($null -ne $it) { $it.StopInstallation() }
}
