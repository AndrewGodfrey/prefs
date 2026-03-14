#Requires AutoHotkey v2

; This is destructive (it loses current selection and slightly moves the IP)
; But maybe it's handy, for F1 at least.
select_wordAroundIp() {
    Send("^{Left}")
    Send("^+{Right}")
}

; In Kusto Data Explorer, the F1 function is dog-slow. Do a web search instead (the way SlickEdit does it).
; Hopefully this window class is stable - it has a guid in it, hopefully there's just one for all versions of KDE on all machines.
#HotIf WinActive("ahk_class HwndWrapper[DefaultDomain;;9818f172-075c-48a7-b99a-a0283262db48]")
F1::
{
    ;; Test case: substring

    ; Trying something: Select current word
    select_wordAroundIp()

    if (!get_normalizedSelectionFromApp(&NormalizedInputString))
        return

    launch_webSearch("kusto query language " . NormalizedInputString)
}
#HotIf
