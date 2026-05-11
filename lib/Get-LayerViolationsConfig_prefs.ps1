# Layer violation config for the 'prefs' repo.
# Higher layers (de) may augment this config when scanning prefs.
#
# Own bannedPatterns would need assembled strings to avoid self-flagging, but are currently empty.
# augmentPrat patterns are safe to write literally — prefs is never scanned against them.

@{
    bannedPatterns = @()
    augmentPrat    = @{
        bannedPatterns = @(
            @{
                pattern     = "~/prefs/"
                description = "~/prefs/ reference (prefs layer — not available in standalone prat)"
            }
        )
    }
}
