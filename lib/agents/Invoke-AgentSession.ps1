param(
    [string]      $Harness,
    [scriptblock] $LaunchHook,
    [hashtable]   $Context
)

$resumeSid = $null
for ($i = 0; $i -lt $ARGS.Count - 1; $i++) {
    if ($ARGS[$i] -eq '--resume') { $resumeSid = $ARGS[$i + 1]; break }
}

# Prefs's own knowledge of claude's and pi's args — the only harness-specific data hardcoded in this
# file. de's Get-AgentHarnesses doesn't need to repeat this to select either; it only matters for a
# harness prefs has no built-in knowledge of (the "augmenting" case in getHarnessDescriptor below).
# pi has no supportsAddDir (it has never gotten --add-dir — preserved here, not a new choice) and an
# additionalArgs tail (its --skill flag) beyond what claude needs; additionalArgs is generic, so a
# de-supplied custom harness could use it too. copilot keeps its own switch case below (a bespoke
# file-based context injection, not reducible to these properties); any other harness (built-in or a
# de-supplied custom one) is handled generically in `default`.
function getBuiltinHarnessDescriptors {
    return @(
        @{ name = 'claude'; supportsAddDir = $true; contextArgStyle = 'append-system-prompt' }
        @{ name = 'pi'; contextArgStyle = 'append-system-prompt'; additionalArgs = @('--skill', './.claude/skills/') }
    )
}

# The descriptor for one harness: the built-in if it's claude/pi, else its own entry from the
# registry (the augmenting case — a harness prefs has no built-in knowledge of supplies its full
# descriptor itself). $null for copilot (handled by its own switch case) or a name neither source
# knows.
function getHarnessDescriptor([string] $harness) {
    if ($harness -eq 'copilot') { return $null }
    $builtin = @(getBuiltinHarnessDescriptors | Where-Object { $_.name -eq $harness }) | Select-Object -First 1
    if ($builtin) { return $builtin }
    return @(Get-AgentHarnesses | Where-Object { $_ -and $_.name -eq $harness }) | Select-Object -First 1
}

$harnessDescriptor = getHarnessDescriptor $Harness

$ctxArgs = @()
if ($Context.targetRepo -and (($Harness -eq 'copilot') -or ($harnessDescriptor -and $harnessDescriptor.supportsAddDir))) {
    $ctxArgs = @('--add-dir', $Context.targetRepo)
}

# Re-evaluate the current role's repo-skill junctions on every launch, so newly-added (or removed)
# repo skills, and branch switches that swap the junction targets, are picked up without a redeploy.
# A sync failure shouldn't block the session — warn and continue with whatever skills are present.
if ($Context.repoSkills) {
    try {
        $skillsDir = Join-Path $Context.roleDir '.claude/skills'
        Sync-RepoSkillJunctions -RepoSkills $Context.repoSkills -SkillsDir $skillsDir -ResolveRepoRoot { param($id) Get-PratRepoRoot $id }
    } catch {
        Write-Warning "Sync-RepoSkillJunctions failed: $_"
    }
}

# Copy the target repos' custom agents into <roleDir>/subagents, and expose that to both
# Claude Code and Copilot via junctions at <roleDir>/.claude/agents and <roleDir>/.github/agents.
# Also syncs repo instructions into <roleDir>/subinstructions with a .github/instructions junction.
# Always called (not gated on repoAgents) so that removing a role's repoAgents config also cleans
# up any subagents/ and harness junctions synced by an earlier run.
try {
    $syncArgs = @{ RoleDir = $Context.roleDir; ResolveRepoRoot = { param($id) Get-PratRepoRoot $id } }
    $syncArgs.RepoAgents = $Context.repoAgents
    if ($Context.repoInstructions) { $syncArgs.RepoInstructions = $Context.repoInstructions }
    Sync-RoleAgents @syncArgs
} catch {
    Write-Warning "Sync-RoleAgents failed: $_"
}

$launchCwd = $PWD.Path
Push-Location $Context.roleDir
$envToken = @{}
try {
    $envToken = Set-EnvTemp @{
        # Read by agent-statusline.ps1, so it can show where 'cl' was launched from rather than the role
        # dir it pushes into above (Claude Code reports cwd as its process cwd, which is the role dir).
        CL_LAUNCH_CWD = $launchCwd
    }
    switch ($Harness) {
        'copilot' {
            $ctxDir = $null
            if ($Context.contextMessage) {
                $ctxDir = Join-Path $env:TEMP "copilot-ctx-$([guid]::NewGuid().ToString('N'))"
                New-Item -ItemType Directory -Path $ctxDir -Force | Out-Null
                $Context.contextMessage | Set-Content (Join-Path $ctxDir 'session-context.instructions.md') -Encoding utf8
                $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = $ctxDir
            }
            try {
                & $LaunchHook $resumeSid ($ctxArgs + $ARGS)
            } finally {
                if ($ctxDir) {
                    Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
                    Remove-Item $ctxDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        default {
            if (-not $harnessDescriptor) { throw "Unknown harness: $Harness" }
            $defaultArgs = $ctxArgs
            if ($harnessDescriptor.contextArgStyle -eq 'append-system-prompt' -and $Context.contextMessage) {
                $defaultArgs = $defaultArgs + @('--append-system-prompt', $Context.contextMessage)
            }
            if ($harnessDescriptor.additionalArgs) {
                $defaultArgs = $defaultArgs + @($harnessDescriptor.additionalArgs)
            }
            & $LaunchHook $resumeSid ($defaultArgs + $ARGS)
        }
    }
} finally {
    Pop-Location
    Restore-Env $envToken
}
