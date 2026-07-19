param($installationTracker, [string[]] $Suppress = @(), [string[]] $Enable = @(), [hashtable] $Config = @{})

$stage = $installationTracker.StartStage('agentConfig')

Install-HarnessIntegration $stage 'claude' -Suppress $Suppress -Enable $Enable -Config $Config
Install-HarnessIntegration $stage 'copilot'

$installationTracker.EndStage($stage)
# OmitFromCoverageReport: pure orchestration/file I/O, not worth the mocking cost
