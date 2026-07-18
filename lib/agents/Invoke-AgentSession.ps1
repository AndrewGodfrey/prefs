param(
    [string]      $Harness,
    [scriptblock] $LaunchHook,
    [hashtable]   $Context
)

$resumeSid = $null
for ($i = 0; $i -lt $ARGS.Count - 1; $i++) {
    if ($ARGS[$i] -eq '--resume') { $resumeSid = $ARGS[$i + 1]; break }
}

$ctxArgs = @()
if ($Context.targetRepo -and $Harness -ne 'pi') {
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
        'claude' {
            $claudeArgs = $ctxArgs
            if ($Context.contextMessage) {
                $claudeArgs = $claudeArgs + @('--append-system-prompt', $Context.contextMessage)
            }
            & $LaunchHook $resumeSid ($claudeArgs + $ARGS)
        }
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
        'pi' {
            $piArgs = $ctxArgs
            if ($Context.contextMessage) {
                $piArgs = $piArgs + @('--append-system-prompt', $Context.contextMessage, '--skill', './.claude/skills/')
            }
            & $LaunchHook $resumeSid ($piArgs + $ARGS)
        }

        default   { throw "Unknown harness: $Harness" }
    }
} finally {
    Pop-Location
    Restore-Env $envToken
}
