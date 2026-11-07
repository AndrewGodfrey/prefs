# Records the current agent session's workstream id, for its statusline (agent-statusline.ps1).
# Usage: Set-SessionWorkstreamId 'myproj-123'    (empty string clears it)
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [string] $WorkstreamId,
    [string] $SessionId,
    [string] $WorkstreamDir
)
. "$PSScriptRoot/../lib/agents/sessionWorkstream.ps1"
if (-not $WorkstreamDir) { $PSBoundParameters.Remove('WorkstreamDir') | Out-Null }
if (-not $SessionId) { $PSBoundParameters.Remove('SessionId') | Out-Null }
Set-SessionWorkstreamId @PSBoundParameters
