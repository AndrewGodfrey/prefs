# `prefs` - Andrew's preferences

Public open-source. 
Andrew-specific preferences, excluding sensitive and secret information. 
Usable from vm/cafe machines and from personal/work versions of his `de` repo.

This depends on:
- `$home\prat`:  Public open-source. Usable by anyone. See also: @CLAUDE_prat.md

- When a change logically belongs in `prat`, make it there instead of in this repo.


## Repo structure

- `pathbin/` — scripts on PATH; `Get-DevEnvironments.ps1` chains prefs into prat's overlay mechanism
- `lib/inst/` — bootstrap: `Install-Prefs.ps1`
- `lib/` — `deploy_prefs.ps1` (main deploy entry point)

## Standalone bootstrap (cafe/VM)

```powershell
git clone https://github.com/AndrewGodfrey/prefs.git $home/prefs
~/prefs/lib/inst/Install-Prefs.ps1
~/prefs/lib/deploy_prefs.ps1
```

## Dev environment chain

```
de's Get-DevEnvironments:    [de, prefs, prat]
prefs's Get-DevEnvironments: [prefs, prat]    ← standalone works
prat's Get-DevEnvironments:  [prat]
```

Files use the `_prefs` suffix (e.g. `sshconfig_prefs.ps1`) following the `_de`/`_prat` convention.
See `Resolve-PratLibFile` in prat for the overlay mechanism.
