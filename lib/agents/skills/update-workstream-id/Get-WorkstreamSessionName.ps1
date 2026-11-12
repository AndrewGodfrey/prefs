[CmdletBinding(DefaultParameterSetName = 'Bare')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^\s:]+$')]
    [string] $WorkstreamId,

    [Parameter(Mandatory, ParameterSetName = 'Titled')]
    [ValidatePattern('^[^\r\n]+$')]
    [string] $OriginalSessionName,

    [ValidateRange(1, [int]::MaxValue)]
    [int] $MaxLength = 40
)

if ($PSCmdlet.ParameterSetName -eq 'Bare') {
    if ($WorkstreamId.Length -gt $MaxLength) {
        throw "Workstream ID '$WorkstreamId' exceeds the session name limit $MaxLength."
    }
    return $WorkstreamId
}

$prefix = "${WorkstreamId}: "
$available = $MaxLength - $prefix.Length
if ($available -lt 1) {
    throw "Session name limit $MaxLength leaves no room for the original title after '$prefix'."
}

$title = $OriginalSessionName
if ($title.Length -gt $available) {
    if ([char]::IsHighSurrogate($title[$available - 1])) { $available-- }
    if ($available -lt 1) { throw 'Session name limit leaves no room for the original title.' }
    $title = $title.Substring(0, $available)
}

$prefix + $title
