param($installationTracker)
$stage = $installationTracker.StartStage('mouse settings')

$path = "HKCU:\Control Panel\Mouse"

#   Defaults I see on Win 10:
#
#   "MouseSensitivity"="10"
#   "MouseSpeed"="1"
#   "MouseThreshold1"="6"
#   "MouseThreshold1"="10"

Install-RegistryStringValue $stage $path "MouseSensitivity" "13"

if ($stage.DidUpdate()) {
    Write-Host -ForegroundColor Red 'NOTE: Must sign out and sign in again, for mouse settings to take effect'
}

$installationTracker.EndStage($stage)
