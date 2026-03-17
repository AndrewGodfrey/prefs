param($installationTracker, [string[]] $Suppress = @())
$stage = $installationTracker.StartStage('vscode')

Install-WingetPackage $stage "Microsoft.VisualStudioCode" "$env:localappdata\Programs\Microsoft VS Code" `
    -AlternatePaths @("C:\Program Files\Microsoft VS Code")

if ("vscodeSignin" -notin $Suppress) { $stage.EnsureManualStep("vscode\signin", @"
Sync settings:
- Check on an existing machine that settings sync is on. It seems to turn itself off.
- Launch vscode ("code" or Start Menu)
- Pin it to the taskbar
- File > Preferences > Backup and Sync Settings ...
- Click "Sign in". Sign in using github.
- Now... wait. It will slowly sync settings and install extensions. It will prompt to reload the window sometimes.
- It seems like maybe if I close and reopen the app, it loads more installed extensions than it did before.
"@) }

<#
Here's a best-effort list of extensions and settings I set up ... which are now synced...
  Customizations:
  - bind "workbench.action.openGlobalKeybindings" to Ctrl-Alt-Shift-F10
  - I've put a PSScriptAnalyzerSettings.psd1 at the root of de. Not sure if vscode picks it up when it does analysis - I don't know how to trigger that. But works when running anaylsis explicitly.
  - bind "Go to Bracket" to "Ctrl + ]", when "editorTextFocus". Apparently don't need to unbind the default "Indent Line" command (maybe User overrides System?)

  Extensions:
  - alefragnani.numbered-bookmarks
  - bierner.markdown-mermaid: For viewing mermaid diagrams in Markdown files
  - Gruntfuggly.todo-tree
  - thqby.vscode-autohotkey2-lsp
    - change its "interpreter path" setting to:
      $home\AppData\Local\programs\AutoHotkey\v2\AutoHotkey64.exe
    - Note: I was previously using "mark-wiemer.vscode-autohotkey-plus-plus". But it's winding down.
  - ms-vscode.hexeditor
  - ivoh.openfileatcursor
    - trying default bindings - Alt-D and Ctrl-Shift-Alt-D
  - Pester Tests (Pester)
  - PowerShell (Microsoft)
  - R.paste-markdown
  - rsbondi.highlight-words
  - ryanluker.vscode-coverage-gutters
    - modify the setting "coverage-gutters.coverageFileNames" - add "auto/testRuns/last/coverage.xml" to it.
  - shd101wyy.markdown-preview-enhanced
    - change key bindings for "open preview" and "open preview to the side":
      - The default "Ctrl + Shift + V" doesn't work because I'm using ditto. So I use "Ctrl + K Ctrl + V" instead.
      - The other thing is to unbind the built-in editor's preview keys, and to remove the "when" clause from the MPE bindings.
        I haven't investigated why but they don't work for me with the default "when" clause.
  - Some Python things, not sure when I did those
#>

$installationTracker.EndStage($stage)
