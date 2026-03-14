#Requires AutoHotkey v2
#SingleInstance force

; A set of shortcuts where "CapsLock" is the modifier key, which I'll prefix as "CL-".
;
; More handy
; ----------
; Use these when there's enough context, like "KB5023773", that the tool can decide what to launch:
;
; CL-A: Auto-launch via the line of text under the mouse cursor.
; CL-Q: Auto-launch via the current selection.
; CL-C: Auto-launch via the current clipboard contents.
;
; For Windows Terminal - where these caps-lock combos interfere with clipboard selection - alternative shorcuts are
; Ctrl-Alt-A and Ctrl-Alt-Q.
;
;
; Less handy
; ----------
; Select some text, and then use one of these to interpret it in a particular way:
;
; CL-S: Start the given path in windows explorer (similar to doing "start <foo>" from a command prompt)
; CL-W: do a Web search
; CL-M: do a Web search in Microsoft documentation (learn.microsoft.com)
; CL-E: Edit a file (in notepad, or your configured editor - see EditorIntegration.ahk)
; CL-J: copy JSON data to a temp file, then open it in configured editor
;
;
; Miscellaneous
; -------------
;
; Ctrl-CL-R: force-Restart the computer
; CL-H: a Test hook, for iterating
; Ctrl-Alt-V: A way to paste clipboard data into NoVNC. Not sure why this is needed.
;
;

; Function naming convention:
; - If it's a pure function, camelCase noun describing what it returns.
; - Otherwise: <verb>_<what, using camelCase>


; #Warn  ; Enable warnings to assist with detecting common errors.
A_WorkingDir := A_ScriptDir  ; Ensures a consistent starting directory.

#Include ..\..\prat\lib\AutoHotkey
#Include EditorIntegration.ahk
#Include InputFromSelection.ahk
#Include LaunchThings.ahk
#Include MatchThings.ahk
#Include AutoLaunch.ahk

CapsLock & S::
{
    ;; Start the given path
    ;  Test case:
    ;    calc
    if !get_normalizedSelectionFromApp(&NormalizedInputString)
        return

    Run(NormalizedInputString)
}

CapsLock & W::
{
    ;; web search
    ; Test case: KB4032258
    if !get_normalizedSelectionFromApp(&NormalizedInputString)
        return

    launch_webSearch(NormalizedInputString)
}

CapsLock & M::
{
    ;; MS doc search
    ; Test case: Powershell
    if !get_normalizedSelectionFromApp(&NormalizedInputString)
        return

    launch_msdocSearch(NormalizedInputString)
}

CapsLock & E::
{
    ;; Open the file in your configured editor
    ;  Test cases:
    ;    C:\Windows\System32\drivers\etc\hosts
    ;    C:\Windows\System32\drivers\etc\hosts:6S
    if !get_normalizedSelectionFromApp(&NormalizedInputString)
        return

    if match_filenameAndLine(NormalizedInputString, &Filename, &LineNumber) > 0 {
        findAndlaunch_fileInEditor(Filename, LineNumber)
    }
}

; CL-J: view some JSON data
; Writes the given JSON data to a temp file, then opens it in your configured editor.
; For vscode you can then do Alt-Shift-F to format it readably.
;
; Test case:
;    {"Name":"foo","Value":{"a":1,"b":"two"},"Items":[1,22,3]}
CapsLock & J::
{
    if !get_normalizedSelectionFromApp(&NormalizedInputString)
        return

    launch_ViewJson(NormalizedInputString)
}

;; Autolaunch
; Test cases:
;  See KB1234
;  Host overrides are in C:\Windows\System32\drivers\etc\hosts
;  See this line: C:\Windows\System32\drivers\etc\hosts:6

^!a::
CapsLock & A::
{
    select_lineUnderMouse()
    if (!get_normalizedSelectionFromApp(&NormalizedInputString))
        return

    autoLaunch(NormalizedInputString)
}

^!q::
CapsLock & Q::
{
    if (!get_normalizedSelectionFromApp(&NormalizedInputString))
        return

    autoLaunch(NormalizedInputString)
}

CapsLock & C::
{
    autoLaunch(normalizedSelection(A_Clipboard))
}


; Ctrl-CL-R: force-Restart the computer
;
; But disable this if the current window is a Remote Deskop client, since you probably don't mean to restart
; the local machine in that case.
#HotIf !WinActive("ahk_class TscShellContainerClass")
CapsLock & R::
{
    if GetKeyState("Ctrl")
        Run("powershell.exe -NoProfile -Command Restart-Computer -Force", ,"Min")
}
#HotIf

CapsLock & H::
{
    class := WinGetClass("A")
    title := WinGetTitle("A")
    MsgBox("The active window has class " . class . ", title " . title)
}


; Ctrl-Alt-V: A way to paste clipboard data into NoVNC. Not sure why this is needed. Source: https://forum.proxmox.com/threads/novnc-copy-paste-not-works.19773/
^!v::
{
	SetKeyDelay(35, 15)
	SendText(A_Clipboard)
}
