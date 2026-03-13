# DISABLED FOR NOW
#
# I was trying:
#
#   Install-RegistryStringValue $stage $path "AutoRepeatDelay" "200"
#   Install-RegistryStringValue $stage $path "AutoRepeatRate" "15"
#   Install-RegistryStringValue $stage $path "DelayBeforeAcceptance" "6"
#   Install-RegistryStringValue $stage $path "Flags" "59"
#
# and it had these problems:
# 1) Over Remote Desktop, I often type one key and get 10 characters, or 20.
# 2) Over Remote Desktop, "Fn-Alt-PgUp/PgDn" (i.e. remote Alt-Tab/Alt-Shift-Tab) don't work at all.
# 3) Locally, "Ctrl-Shift-Arrow key" (to select next/prev word) frequently don't work.
#    I think it's whenever I press Ctrl and Shift at the same time.
#
# A further problem is that you have to logoff & logon to make these changes take effect.
# This can be avoided by using the Win32 API SystemParametersInfo(SPI_SETFILTERKEYS (0x33), sizeof(FILTERKEYS), pFilterKeysStruct, SPIF_SENDCHANGE).
# (or... does sending a WM_SETTINGCHANGE message cause Windows to refresh from the registry? That would be nice. Probably not though).
param($installationTracker)
$stage = $installationTracker.StartStage('keyboard settings')

$path = "HKCU:\Control Panel\Accessibility\Keyboard Response"

#   Defaults I see on Win 10:
#
#   "AutoRepeatDelay"="1000"
#   "AutoRepeatRate"="500"
#   "BounceTime"="0"
#   "DelayBeforeAcceptance"="1000"
#   "Flags"="126"


# Here's what the "Keyboard Properties" UI sets. I'm not sure if this matters, for now I'm ignoring it.
#
#   HKCU\Control Panel\Keyboard\KeyboardSpeed  Type: REG_SZ, Length: 6, Data: 24
#   HKCU\Control Panel\Keyboard\KeyboardDelay  Type: REG_SZ, Length: 4, Data: 1

Install-RegistryStringValue $stage $path "AutoRepeatDelay" "1000"
Install-RegistryStringValue $stage $path "AutoRepeatRate" "500"
Install-RegistryStringValue $stage $path "DelayBeforeAcceptance" "1000"
Install-RegistryStringValue $stage $path "Flags" "126"

if ($stage.DidUpdate()) {
    Write-Host -ForegroundColor Red 'NOTE: Must sign out and sign in again, for keyboard settings to take effect'
}

$installationTracker.EndStage($stage)
