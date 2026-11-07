# Each agent session's workstream id, for agent-statusline.ps1 to show. A session gets one when its
# agent runs pathbin/Set-SessionWorkstreamId.ps1: the CLI harnesses give an agent no way to change its
# own session name. Several sessions can share one workstream id.
. "$PSScriptRoot/agentHarnesses.ps1"

$script:sessionWorkstreamRetentionDays = 30
$script:sessionWorkstreamMaxLength = 40

# Where every session's id file lives, as an absolute path (prig.ps1 hands it to prig).
function Get-SessionWorkstreamDir {
    [IO.Path]::GetFullPath("$PSScriptRoot/../../auto/sessionWorkstreams")
}

function Test-AgentSessionId([string] $SessionId) {
    $SessionId -match '^[A-Za-z0-9_-]+$'
}

function Set-SessionWorkstreamId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [string] $WorkstreamId,
        [string] $SessionId = (Get-CurrentAgentSessionId),
        [string] $WorkstreamDir = (Get-SessionWorkstreamDir)
    )
    if (-not $SessionId) { throw "No session id: pass -SessionId, or run inside an agent session." }
    if (-not (Test-AgentSessionId $SessionId)) { throw "Invalid session id: '$SessionId'" }

    $file = Join-Path $WorkstreamDir "$SessionId.txt"
    if (-not $WorkstreamId) {
        Remove-Item $file -ErrorAction SilentlyContinue
        return
    }
    New-Item -ItemType Directory -Path $WorkstreamDir -Force | Out-Null
    Set-Content -Path $file -Value $WorkstreamId -NoNewline -Encoding utf8NoBOM

    $cutoff = (Get-Date).AddDays(-$script:sessionWorkstreamRetentionDays)
    Get-ChildItem $WorkstreamDir -Filter '*.txt' -File | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item
}

# Returns '' rather than throwing: this runs on every statusline refresh.
function Read-SessionWorkstreamId([string] $SessionId, [string] $WorkstreamDir = (Get-SessionWorkstreamDir)) {
    if (-not (Test-AgentSessionId $SessionId)) { return '' }
    $file = Join-Path $WorkstreamDir "$SessionId.txt"
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    $text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return '' }
    $line = ($text -split '\r?\n')[0] -replace '[\x00-\x1f\x7f]', ''
    if ($line.Length -gt $script:sessionWorkstreamMaxLength) {
        $line = $line.Substring(0, $script:sessionWorkstreamMaxLength - 3) + '...'
    }
    $line
}
