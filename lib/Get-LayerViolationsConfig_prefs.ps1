# Layer violation config for the 'prefs' repo.
# Higher layers (de) may augment this config when scanning prefs.
# Top-level bannedPatterns apply to prefs and every scanned layer below it (prat); they would
# need assembled strings to avoid self-flagging, and are currently empty. augmentPrat patterns
# are safe to write literally — prefs is never scanned against them. Patterns are
# case-insensitive regexes.

@{
    bannedPatterns = @()
    augmentPrat    = @{
        bannedPatterns = @(
            @{
                pattern     = "~/prefs/"
                description = "~/prefs/ reference (prefs layer — not available in standalone prat)"
            },
            @{
                pattern     = "CL_PLAN_FILE|CL_LAUNCH_CWD|Launch-Plan"
                description = "prefs-layer identifier (not available in standalone prat)"
            }
        )
    }
}
