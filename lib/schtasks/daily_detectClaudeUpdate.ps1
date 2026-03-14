# .SYNOPSIS
# Checks if a newer version of Claude Code is available. If so, signals 'd' to run the installer
# next time it is invoked — rather than running the installer directly, which can emit console
# messages that expect a human to be watching.

$logFile = "$home\prat\auto\log\daily_detectClaudeUpdate.log"
Start-Transcript -Path $logFile > $null

$GcsBucketUrl = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
$report = { param($status, $msg) & "$home\prefs\pathbin\Report-ScheduledTaskResult.ps1" -TaskName "detectClaudeUpdate" -Status $status -Message $msg }

try {
    &$home\prat\lib\profile\Add-PratBinPaths.ps1

    # Fragility check: download install.ps1 and verify it still references our expected GCS bucket URL.
    # If it doesn't, our version-fetch assumptions are broken — notify and abort rather than silently misbehave.
    $installScriptText = Invoke-RestMethod "https://claude.ai/install.ps1"
    if ($installScriptText -notlike "*$GcsBucketUrl*") {
        & $report 'Failure' "install.ps1 no longer contains expected GCS URL. Update script needs attention."
        return
    }

    # Check what the latest available version is
    $latestVersion = (Invoke-RestMethod "$GcsBucketUrl/latest").Trim()

    # Check installed version: `claude --version` outputs e.g. "2.1.71 (Claude Code)"
    $claudeOutput = (claude --version 2>&1)
    if ($claudeOutput -notmatch '^(\S+)') {
        throw "Could not parse 'claude --version' output: $claudeOutput"
    }
    $installedVersion = $matches[1]

    if ([System.Version]$installedVersion -ge [System.Version]$latestVersion) {
        & $report 'Success' "Claude is up to date ($installedVersion)"
        return
    }

    Write-Host "Newer Claude available: $latestVersion (installed: $installedVersion). Signalling 'd' to update."

    # Signal 'd' to re-run installClaude next time by clearing its DB entry.
    # 'd' stores state in "$home\prat\auto\instDb". The step ID "pkg\claude:1.1" (from internal_installPratPackage)
    # is parsed by ParseStepIdAndVersion into itemId="pkg\claude", version="1.1", which maps to this file:
    $dbEntry = "$home\prat\auto\instDb\pkg\claude.txt"
    if (Test-Path $dbEntry) {
        Remove-Item $dbEntry
        Write-Host "Cleared DB entry: $dbEntry"
    }

    & $report 'Success' "Signalled 'd' to update Claude from $installedVersion to $latestVersion"

} catch {
    $msg = "Claude auto-update check failed: $_"
    Write-Host $msg
    & $report 'Failure' $msg
} finally {
    Stop-Transcript > $null
}
