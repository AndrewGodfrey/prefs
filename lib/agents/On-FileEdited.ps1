# PostToolUse hook for Write/Edit (registered in Get-ClaudeUserSettings_prefs.ps1). Two jobs:
#   1. Repair-FileLineEndings — convert LF to CRLF where the repo's git config requires it.
#   2. Get-MarkdownWidthFeedback — check an edited markdown file against the 120-char wrap limit
#      (Find-LongMarkdownLines' default) and feed any findings back to the agent.
#
# Output contract (CC PostToolUse): exit 2 with the findings on stderr feeds them back to the
# agent; exit 0 with no output reports nothing. Never emit to stdout — Claude Code interprets
# hook stdout as instructions.

# The checker lives in prat (the mechanism); this hook (the policy) is prefs'. $home/prat is the
# one layer path that is itself the anchor convention, and hooks run in contexts too minimal for
# layer discovery.
. "$home/prat/pathbin/Find-LongMarkdownLines.ps1"

# When CRLF conversion is needed:
#
#   Case 1 — .gitattributes has an explicit eol=crlf rule for this file.
#             Detected via: git check-attr eol -- <file> → "eol: crlf"
#
#   Case 2 — core.autocrlf=true + core.safecrlf=true/warn in git config.
#             git refuses (or warns) when staging LF files because the round-trip
#             check fails: LF → stored as LF → checkout gives CRLF ≠ original LF.
#             Detected via: git config core.autocrlf + git config core.safecrlf.
#
# When CRLF conversion is NOT needed:
#
#   - Not inside a git repo → skip
#   - .gitattributes has explicit eol=lf for this file → skip (respect LF-only rule)
#   - core.autocrlf=true but safecrlf=false/unset → git handles silently, no need to convert
#   - core.autocrlf=input or false → no CRLF conversion in git pipeline, skip
#   - File has no LF bytes (already CRLF or binary) → skip conversion step
#   - macOS CR-only (\r) endings: modern macOS uses LF; old CR-only is a legacy
#     artifact git doesn't handle specially — not worth supporting.
function Repair-FileLineEndings($filePath) {
    if (-not $filePath -or -not (Test-Path $filePath -PathType Leaf)) { return }

    # Determine if CRLF conversion is needed before reading the file —
    # git config lookups are cheaper than reading file contents.

    # Must be inside a git repo
    $parentDir = Split-Path $filePath -Parent
    $repoRoot = git -C $parentDir rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { return }

    # Check .gitattributes eol attribute for this file (Case 1)
    $attrOutput = git -C $repoRoot check-attr eol -- $filePath 2>$null
    if ($attrOutput -match ': eol: lf') { return }   # Explicitly LF — respect it
    $needsCrlf = $attrOutput -match ': eol: crlf'

    # Check git config for autocrlf + safecrlf (Case 2)
    if (-not $needsCrlf) {
        $autocrlf = git -C $repoRoot config core.autocrlf 2>$null
        if ($autocrlf -eq 'true') {
            $safecrlf = git -C $repoRoot config core.safecrlf 2>$null
            if ($safecrlf -eq 'true' -or $safecrlf -eq 'warn') {
                $needsCrlf = $true
            }
        }
    }

    if (-not $needsCrlf) { return }

    # Read file and convert: replace bare LF with CRLF
    # (idempotent — existing CRLF pairs are not doubled; skip binary files)
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ([Array]::IndexOf($bytes, [byte]10) -lt 0) { return }  # No LF bytes — nothing to do
    if ([Array]::IndexOf($bytes, [byte]0)  -ge 0) { return }  # Null bytes → binary, skip
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $converted = $text -replace '\r?\n', "`r`n"
    [System.IO.File]::WriteAllText($filePath, $converted, [System.Text.UTF8Encoding]::new($false))
}

function Get-MarkdownWidthFeedback($hookData) {
    $path = $hookData.tool_input.file_path
    if (-not $path -or $path -notmatch '\.md$') { return $null }
    if (-not (Test-Path $path -PathType Leaf)) { return $null }

    $findings = @(Get-LongMarkdownLineFindings -Path $path)
    if ($findings.Count -eq 0) { return $null }

    $lines = @('Markdown lines over 120 chars — wrap at natural phrase boundaries (shorten headings instead of splitting):')
    foreach ($f in $findings) {
        $lines += ('{0}:{1}: {2} chars' -f $f.Path, $f.Line, $f.Length)
    }
    return $lines -join "`n"
}

if ($MyInvocation.InvocationName -ne '.') {
    $hookData = ([Console]::In.ReadToEnd()) | ConvertFrom-Json
    Repair-FileLineEndings $hookData.tool_input.file_path | Out-Null
    $feedback = Get-MarkdownWidthFeedback $hookData
    if ($feedback) {
        [Console]::Error.WriteLine($feedback)
        exit 2
    }
}
