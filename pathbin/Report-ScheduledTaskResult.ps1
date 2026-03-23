# .SYNOPSIS
# Reports the outcome of a scheduled task (success or failure).
# For now: writes to the current transcript/stdout, which the task scheduler captures in the log.
param(
    [string] $TaskName,
    [ValidateSet('Success', 'Failure')] [string] $Status,
    [string] $Message
)

$prefix = if ($Status -eq 'Failure') { '[FAILURE]' } else { '[SUCCESS]' }
Write-Host "$prefix $TaskName`: $Message"
