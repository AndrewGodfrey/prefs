#Requires -PSEdition Core

# Updates PowerShell help, ignoring errors because this is flaky and I don't care so much about the flaky cases I've seen so far.
param($installationTracker)
$stage = $installationTracker.StartStage('update PowerShell help')


if (!($stage.GetIsStepComplete("powershell\updatehelp"))) {
    $stage.OnChange()

    # SilentlyContinue is needed because Microsoft doesn't fix broken links. e.g. 2+-year history here: https://github.com/MicrosoftDocs/windows-powershell-docs/issues/139
    Update-Help -ErrorAction SilentlyContinue

    $stage.SetStepComplete("powershell\updatehelp")
}

$installationTracker.EndStage($stage)
