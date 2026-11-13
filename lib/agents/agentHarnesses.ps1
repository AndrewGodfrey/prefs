# The agent-harness registry, layered like agent roles: each layer may contribute a
# `lib/agents/harnesses_<layer>.ps1` returning
#   @{ selected = @(<harness name>...); harnesses = @{ <name> = @{ <property> = <value>... } } }
# A harness's properties merge base-first, so a higher layer wins per property. `selected` (which
# harnesses this dev environment uses, the first being the default) comes from the highest layer
# that declares it. harnesses_prefs.ps1 lists the properties and their consumers.

# The selected harnesses' descriptors, in selection order; with -All, every harness any layer
# describes or selects. A selected name no layer describes gets a bare @{ name = ... }.
function Resolve-AgentHarnessDescriptors([object[]] $Contributions, [switch] $All) {
    $merged   = [ordered]@{}
    $selected = @()
    foreach ($c in $Contributions) {
        if ($c.ContainsKey('selected')) { $selected = @($c.selected) }
        if (-not $c.harnesses) { continue }
        foreach ($name in $c.harnesses.Keys) {
            if (-not $merged.Contains($name)) { $merged[$name] = @{ name = $name } }
            foreach ($k in $c.harnesses[$name].Keys) { $merged[$name][$k] = $c.harnesses[$name][$k] }
        }
    }
    $names = if ($All) { @($merged.Keys) + @($selected | Where-Object { -not $merged.Contains($_) }) } else { $selected }
    foreach ($name in ($names | Select-Object -Unique)) {
        if ($merged.Contains($name)) { $merged[$name] } else { @{ name = $name } }
    }
}

# The layers' contributions, base-first. -HarnessFiles (highest-first, as Resolve-PratLibFile
# returns them) is a test seam.
function Get-AgentHarnessContributions([string[]] $HarnessFiles = @(Resolve-PratLibFile 'lib/agents/harnesses.ps1' -ListAll)) {
    $files = @($HarnessFiles)
    [array]::Reverse($files)
    return @($files | ForEach-Object { & $_ })
}

function Get-AgentHarnessDescriptors([switch] $All) {
    Resolve-AgentHarnessDescriptors (Get-AgentHarnessContributions) -All:$All
}

# The current agent session's id: the value of the one known harness's sessionIdEnvVar that is set.
# Nothing outside an agent session. Each harness sets its own variable, so a session launched from
# another harness's shell sees both; that throws rather than guess which session is "current".
function Get-CurrentAgentSessionId([object[]] $Descriptors = @(Get-AgentHarnessDescriptors -All)) {
    $found = @($Descriptors | Where-Object { $_.sessionIdEnvVar -and [Environment]::GetEnvironmentVariable($_.sessionIdEnvVar) })
    if ($found.Count -gt 1) {
        throw "Ambiguous agent session: session-id variables are set for more than one harness ($(($found | ForEach-Object { "$($_.name): $($_.sessionIdEnvVar)" }) -join ', '))."
    }
    if ($found) { [Environment]::GetEnvironmentVariable($found[0].sessionIdEnvVar) }
}
